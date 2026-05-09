import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_shim.dart';
import 'package:webspace/services/host_lookup.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/services/log_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'abp_filter_parser.dart';
import 'abp_filter_parser_async.dart';

/// Runtime opt-in for the Rust-backed adblock engine. Loaded from
/// SharedPreferences (key: [kUseRustAdblockEngineKey]) on first
/// access and cached. Off by default. Toggling at runtime calls
/// [ContentBlockerService.setRustEngineEnabled], which persists the
/// new value AND triggers a rebuild so the engine spins up / tears
/// down without an app restart.
///
/// When the runtime flag is true but the platform doesn't ship
/// `webspace_adblock` (or the library fails to load), the service
/// falls back to the Dart parser path — the engine is strictly an
/// accelerator, never a precondition.

/// A filter list entry with metadata.
class FilterList {
  final String id;
  String name;
  String url;
  bool enabled;
  DateTime? lastUpdated;
  int ruleCount;
  int skippedCount;

  FilterList({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = false,
    this.lastUpdated,
    this.ruleCount = 0,
    this.skippedCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'lastUpdated': lastUpdated?.toIso8601String(),
        'ruleCount': ruleCount,
        'skippedCount': skippedCount,
      };

  factory FilterList.fromJson(Map<String, dynamic> json) => FilterList(
        id: json['id'],
        name: json['name'],
        url: json['url'],
        enabled: json['enabled'] ?? false,
        lastUpdated: json['lastUpdated'] != null
            ? DateTime.tryParse(json['lastUpdated'])
            : null,
        ruleCount: json['ruleCount'] ?? 0,
        skippedCount: json['skippedCount'] ?? 0,
      );
}

/// Default filter lists added on first initialization.
const List<Map<String, String>> _defaultLists = [
  {
    'id': 'easylist',
    'name': 'EasyList',
    'url': 'https://easylist.to/easylist/easylist.txt',
  },
  {
    'id': 'easyprivacy',
    'name': 'EasyPrivacy',
    'url': 'https://easylist.to/easylist/easyprivacy.txt',
  },
  {
    'id': 'fanboy-social',
    'name': "Fanboy's Social",
    'url': 'https://easylist.to/easylist/fanboy-social.txt',
  },
  {
    'id': 'fanboy-annoyance',
    'name': "Fanboy's Annoyance",
    'url': 'https://easylist.to/easylist/fanboy-annoyance.txt',
  },
];

/// Singleton service for managing ABP filter lists.
///
/// Uses two mechanisms instead of InAppWebView's contentBlockers (which does
/// O(n) regex per request on Android):
/// 1. **Domain blocking** — O(1) hash set lookup in shouldOverrideUrlLoading
/// 2. **Cosmetic filtering** — JavaScript injection with MutationObserver
class ContentBlockerService {
  static const String _listsKey = 'content_blocker_lists';
  static const String _cacheDir = 'content_blocker_cache';

  static ContentBlockerService? _instance;
  static ContentBlockerService get instance =>
      _instance ??= ContentBlockerService._();

  ContentBlockerService._();

  List<FilterList> _lists = [];

  /// Aggregated blocked domains from all enabled lists.
  Set<String> _blockedDomains = {};

  /// Aggregated exception domains (@@||domain^) that override blocked domains.
  Set<String> _exceptionDomains = {};

  /// Aggregated path-anchored network rules: domain -> compiled
  /// regexes for the path glob. Compiled once per `_rebuildRules` so
  /// the hot path in [isBlocked] never re-compiles.
  Map<String, List<RegExp>> _blockedDomainPathRegexes = {};

  /// Aggregated cosmetic selectors: domain -> selectors.
  /// Key '' = global selectors.
  Map<String, List<String>> _cosmeticSelectors = {};

  /// Aggregated uBO `:style(...)` rules: domain -> selectors with
  /// custom CSS declarations. Key convention matches [_cosmeticSelectors].
  Map<String, List<StyleRule>> _styleRules = {};

  /// Aggregated text-based hiding rules: domain -> rules.
  Map<String, List<TextHideRule>> _textHideRules = {};

  /// Optional Rust-backed engine for network-block decisions. Built
  /// lazily on the first [_rebuildRules] call when the
  /// [kUseRustEngineForNetwork] flag is set AND the platform ships
  /// the native library. Disposed and re-created on each rebuild
  /// (the underlying engine has no incremental update API).
  AdblockEngine? _rustEngine;

  /// Whether the Rust engine is currently available — true only if
  /// the runtime flag is on, the library loaded, and parsing
  /// succeeded. Tested via [usingRustEngine] for diagnostics + tests.
  bool get usingRustEngine => _rustEngine != null;

  /// Cached runtime flag (mirrors SharedPreferences). Read by
  /// [_maybeRebuildRustEngine]; written by [setRustEngineEnabled] and
  /// loaded on first [_rebuildRules] call after [initialize].
  bool _rustEngineEnabled = false;

  /// Whether the user has opted in to the Rust engine. UI bindings
  /// (settings page) read this for the toggle's current value.
  bool get rustEngineEnabled => _rustEngineEnabled;

  /// Whether the platform actually ships the engine library, regardless
  /// of the user's preference. UI bindings should grey the toggle out
  /// when this is false — flipping it on otherwise just logs a warning
  /// and silently uses the Dart engine. Cheap to call: it tries the
  /// `DynamicLibrary.open` once and caches the result.
  bool get rustEngineSupportedOnPlatform {
    if (_rustEngineSupported != null) return _rustEngineSupported!;
    if (Platform.isAndroid) {
      // Android Dart-side has no FFI access to the bundled .so —
      // probing AdblockEngine.load would always return null. The
      // native side is what actually runs the engine on Android,
      // so consult its support flag via the method channel. The
      // Dart-side `_rustEngine` field stays null here; the engine
      // lives entirely in JNI land. Cosmetic + main-doc decisions
      // re-route through the native engine via a follow-up phase
      // (currently they still use the Dart parser on Android).
      // Probe is async; cache eagerly via initialize().
      return _rustEngineSupported ?? false;
    }
    final probe = AdblockEngine.load('');
    _rustEngineSupported = probe != null;
    probe?.dispose();
    return _rustEngineSupported!;
  }
  bool? _rustEngineSupported;

  /// Toggle the Rust engine on / off, persist to SharedPreferences,
  /// and rebuild rules so the engine spins up / tears down without
  /// an app restart. Safe to call repeatedly.
  Future<void> setRustEngineEnabled(bool enabled) async {
    if (_rustEngineEnabled == enabled) return;
    LogService.instance.log('ContentBlocker',
        'Rust engine toggle flipped to $enabled (was ${!enabled})',
        level: LogLevel.info);
    _rustEngineEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kUseRustAdblockEngineKey, enabled);
    await _rebuildRules();
  }

  /// All configured filter lists.
  List<FilterList> get lists => List.unmodifiable(_lists);

  /// Total rule count across all enabled lists.
  int get totalRuleCount =>
      _lists.where((l) => l.enabled).fold(0, (sum, l) => sum + l.ruleCount);

  /// Whether any rules are loaded.
  bool get hasRules =>
      _blockedDomains.isNotEmpty ||
      _blockedDomainPathRegexes.isNotEmpty ||
      _cosmeticSelectors.isNotEmpty ||
      _styleRules.isNotEmpty ||
      _textHideRules.isNotEmpty;

  /// Aggregated ABP blocked domains across all enabled lists. Shared with
  /// the sub-resource interceptor (native Android + iOS JS Bloom) so ABP
  /// network blocking extends beyond main-document navigations.
  Set<String> get blockedDomains => _blockedDomains;

  /// Listeners invoked when the aggregated rule set changes (download,
  /// toggle, remove, re-init). main.dart uses this to re-push domains to
  /// the native interceptor and invalidate the merged JS Bloom.
  final List<VoidCallback> _rulesChangedListeners = [];

  void addRulesChangedListener(VoidCallback listener) {
    _rulesChangedListeners.add(listener);
  }

  void removeRulesChangedListener(VoidCallback listener) {
    _rulesChangedListeners.remove(listener);
  }

  void _notifyRulesChanged() {
    for (final listener in List<VoidCallback>.from(_rulesChangedListeners)) {
      listener();
    }
  }

  /// Per-host decision cache for [isBlocked]. The DNS path uses the same
  /// pattern in [DnsBlockService._dnsBlockCache]; without a cache here,
  /// every sub-resource roundtrip (iOS JS-bridge `blockCheck` /
  /// `blockResourceLoaded`) re-walks the suffix hierarchy even for hosts
  /// already known good. Cleared in [_rebuildRules].
  final HostFifoCache _isBlockedCache = HostFifoCache(2048);

  /// Check if a URL's domain (or any parent domain) is blocked.
  ///
  /// Hot path. Avoids `Uri.parse` (full RFC 3986 validation, allocates a
  /// `Uri` object) by using [extractHost] and short-circuits via
  /// [_isBlockedCache] on repeated hosts. Exception domains (`@@||domain^`)
  /// override blocked domains.
  ///
  /// Path-anchored rules (`||domain^/path`) are checked when the host
  /// has any registered path glob. The per-host cache only stores the
  /// pure-domain decision; path lookups are unmemoised because the
  /// answer depends on the URL's path, not the host alone.
  ///
  /// [sourceUrl] is the page URL the request originated from. Without
  /// it the engine can't evaluate `$domain=` modifiers — those rules
  /// will silently miss. Caller-side: pass `config.url` from the
  /// WebView hook. [requestType] follows ABP's resource-type taxonomy
  /// (`document|subdocument|stylesheet|script|image|font|media|xhr|other`)
  /// and gates `$script`/`$image`/etc. modifiers; pass `'other'` (the
  /// default) when unknown.
  bool isBlocked(
    String url, {
    String sourceUrl = '',
    String requestType = 'other',
  }) {
    final engine = _rustEngine;
    if (engine != null) {
      return engine.shouldBlock(
        url,
        sourceUrl: sourceUrl,
        requestType: requestType,
      );
    }
    if (_blockedDomains.isEmpty && _blockedDomainPathRegexes.isEmpty) {
      return false;
    }
    final host = extractHost(url);
    if (host == null || host.isEmpty) return false;
    if (isHostBlocked(host)) return true;
    if (_blockedDomainPathRegexes.isEmpty) return false;
    if (_exceptionDomains.isNotEmpty && hostInSet(host, _exceptionDomains)) {
      return false;
    }
    final pathRegexes = _collectPathRegexesFor(host);
    if (pathRegexes.isEmpty) return false;
    final pathPart = extractPathAndQuery(url);
    for (final re in pathRegexes) {
      if (re.hasMatch(pathPart)) return true;
    }
    return false;
  }

  /// Like [isBlocked] but the caller already has the host. Skips the
  /// URL-parse step. Path-anchored rules are NOT considered here since
  /// the path is unknown.
  bool isHostBlocked(String host) {
    if (_blockedDomains.isEmpty || host.isEmpty) return false;
    final cached = _isBlockedCache[host];
    if (cached != null) return cached;
    if (_exceptionDomains.isNotEmpty && hostInSet(host, _exceptionDomains)) {
      _isBlockedCache.put(host, false);
      return false;
    }
    final result = hostInSet(host, _blockedDomains);
    _isBlockedCache.put(host, result);
    return result;
  }

  /// Collect every compiled path regex registered against [host] or any
  /// parent domain (`a.b.c.example.com` → `b.c.example.com` → ... →
  /// `example.com`). Stops before the eTLD label, mirroring [hostInSet].
  List<RegExp> _collectPathRegexesFor(String host) {
    if (_blockedDomainPathRegexes.isEmpty) return const [];
    final out = <RegExp>[];
    final exact = _blockedDomainPathRegexes[host];
    if (exact != null) out.addAll(exact);
    int dot = host.indexOf('.');
    while (dot >= 0 && dot < host.length - 1) {
      final parent = host.substring(dot + 1);
      if (!parent.contains('.')) break;
      final hit = _blockedDomainPathRegexes[parent];
      if (hit != null) out.addAll(hit);
      dot = host.indexOf('.', dot + 1);
    }
    return out;
  }

  /// Cached engine result per page URL within one navigation. The
  /// engine call is non-trivial (JSON marshal across FFI), and we
  /// hit it twice per page (early-CSS + post-load cosmetic) plus
  /// once more for the generic scanner exceptions. Cache keyed on
  /// pageUrl; cleared in [_rebuildRules] alongside [_isBlockedCache].
  final Map<String, _EngineCosmeticCache> _engineCosmeticCache = {};

  /// Read-through wrapper around `engine.cosmeticResources(pageUrl)`
  /// returning the slice we care about, with caching. Returns null
  /// when the engine isn't active or returns null.
  _EngineCosmeticCache? _engineCosmeticFor(String pageUrl) {
    final engine = _rustEngine;
    if (engine == null) return null;
    final cached = _engineCosmeticCache[pageUrl];
    if (cached != null) return cached;
    final raw = engine.cosmeticResources(pageUrl);
    if (raw == null) return null;
    final hides = (raw['hide_selectors'] as List? ?? const [])
        .cast<String>()
        .toList();
    final exceptions = (raw['exceptions'] as List? ?? const [])
        .cast<String>()
        .toSet();
    final genericHide = raw['generichide'] == true;
    final entry = _EngineCosmeticCache(
      hides: hides,
      exceptions: exceptions,
      genericHide: genericHide,
    );
    _engineCosmeticCache[pageUrl] = entry;
    LogService.instance.log('ContentBlocker',
        'engine.cosmeticResources($pageUrl) → '
        '${hides.length} hide(s), ${exceptions.length} exception(s)'
        '${genericHide ? ", generichide" : ""}',
        level: LogLevel.debug);
    return entry;
  }

  /// Collect applicable selectors, style rules, and text rules for a
  /// page URL. When the engine is active, the engine's domain-scoped
  /// hide selectors REPLACE the Dart-aggregated ones — adblock-rust's
  /// rule set is the authoritative source. Style rules and text rules
  /// stay on the Dart aggregations until [`procedural_actions`] are
  /// wired through (own phase). Generic class/id selectors continue
  /// to flow through the JS scanner shim, gated on the engine's
  /// `generichide` flag.
  ({
    List<String> selectors,
    List<StyleRule> styleRules,
    List<TextHideRule> textRules,
  }) _collectRules(String pageUrl) {
    final selectors = <String>[];
    final styleRules = <StyleRule>[];
    final textRules = <TextHideRule>[];

    final engineHides = _engineCosmeticFor(pageUrl);
    if (engineHides != null) {
      // Engine returns the full per-URL list (global + domain walk-up
      // + first-party exceptions already applied). Use it verbatim.
      selectors.addAll(engineHides.hides);
      // Style + text rules: Dart parser still owns these. The engine
      // exposes them in `procedural_actions`, but mapping that shape
      // is a separate refactor. Falling through means a list with
      // both engine-supported and engine-unsupported rules still
      // gets full coverage from the Dart side.
    } else {
      final globalSel = _cosmeticSelectors[''];
      if (globalSel != null) selectors.addAll(globalSel);
    }

    final globalStyle = _styleRules[''];
    if (globalStyle != null) styleRules.addAll(globalStyle);
    final globalText = _textHideRules[''];
    if (globalText != null) textRules.addAll(globalText);

    final host = extractHost(pageUrl);
    if (host != null && host.isNotEmpty) {
      String domain = host;
      while (domain.isNotEmpty) {
        // Selector walk-up only when engine is NOT active — the
        // engine already did the walk-up internally.
        if (engineHides == null) {
          final ds = _cosmeticSelectors[domain];
          if (ds != null) selectors.addAll(ds);
        }
        final sr = _styleRules[domain];
        if (sr != null) styleRules.addAll(sr);
        final tr = _textHideRules[domain];
        if (tr != null) textRules.addAll(tr);
        final dotIdx = domain.indexOf('.');
        if (dotIdx < 0) break;
        domain = domain.substring(dotIdx + 1);
      }
    }

    return (selectors: selectors, styleRules: styleRules, textRules: textRules);
  }

  /// Get CSS-only JavaScript for early injection at DOCUMENT_START.
  /// Injects a <style> tag with display:none rules before content renders.
  /// Returns null if no CSS selectors apply.
  String? getEarlyCssScript(String pageUrl) {
    final rules = _collectRules(pageUrl);
    return buildContentBlockerEarlyCssShim(
      selectors: rules.selectors,
      styleRules: rules.styleRules
          .map((r) => (selector: r.selector, declarations: r.declarations))
          .toList(),
    );
  }

  /// Phase 5: generic class/id-targeted selectors from the Rust engine.
  ///
  /// The page-side shim (from `generic_cosmetic_shim.dart`) scans the
  /// loaded DOM for unique classes and ids and sends them across the
  /// `genericCosmeticScan` bridge handler. That handler calls into
  /// here, which forwards to [AdblockEngine.hiddenClassIdSelectors].
  /// Returns the selectors to inject as `display: none !important`.
  ///
  /// Returns empty when:
  ///   * The engine isn't active (Dart parser path handles its own
  ///     generic selectors via [_cosmeticSelectors] already).
  ///   * No filter rule targets any of the page's classes/ids.
  ///
  /// [exceptions] is harvested from the prior `cosmeticResources`
  /// call; passing an empty set is acceptable — the worst case is a
  /// few extra hides on pages that explicitly carve out a selector.
  List<String> genericCosmeticSelectorsFor({
    required String pageUrl,
    required Set<String> classes,
    required Set<String> ids,
    Set<String> exceptions = const <String>{},
  }) {
    final engine = _rustEngine;
    if (engine == null) return const [];
    if (classes.isEmpty && ids.isEmpty) return const [];
    // Carry the page's exception set into the generic lookup so a
    // first-party `#@#.x` allowlist suppresses the matching generic
    // rule. Also short-circuit when the engine's `generichide` flag
    // (effectively `$generichide` in @@||) is set for the page.
    final engineCtx = _engineCosmeticFor(pageUrl);
    if (engineCtx?.genericHide == true) {
      LogService.instance.log('ContentBlocker',
          'engine.hiddenClassIdSelectors($pageUrl) skipped — '
          'page has \$generichide allowlist',
          level: LogLevel.debug);
      return const [];
    }
    final mergedExceptions =
        engineCtx == null || engineCtx.exceptions.isEmpty
            ? exceptions
            : <String>{...exceptions, ...engineCtx.exceptions};
    final result = engine.hiddenClassIdSelectors(
      classes,
      ids,
      exceptions: mergedExceptions,
    );
    LogService.instance.log('ContentBlocker',
        'engine.hiddenClassIdSelectors($pageUrl): '
        '${classes.length} class(es), ${ids.length} id(s) → '
        '${result.length} selector(s)',
        level: LogLevel.debug);
    return result;
  }

  /// Get full JavaScript for injection after page load.
  /// Sets up MutationObserver for dynamic content and text-based hiding.
  /// Returns null if no cosmetic rules apply.
  String? getCosmeticScript(String pageUrl) {
    final rules = _collectRules(pageUrl);
    return buildContentBlockerCosmeticShim(
      selectors: rules.selectors,
      styleRules: rules.styleRules
          .map((r) => (selector: r.selector, declarations: r.declarations))
          .toList(),
      textRules: rules.textRules
          .map((r) => (selector: r.selector, patterns: r.textPatterns))
          .toList(),
    );
  }

  /// Initialize: load list metadata from prefs, parse cached files for enabled lists.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Hydrate the engine flag BEFORE _rebuildRules so the very
      // first rebuild (just below) spins up the engine if the user
      // already opted in on a prior run.
      _rustEngineEnabled = prefs.getBool(kUseRustAdblockEngineKey) ?? false;
      // Probe Android native support eagerly — the synchronous
      // getter falls back to this cached value.
      if (Platform.isAndroid) {
        _rustEngineSupported =
            await WebInterceptNative.isAdblockEngineSupported();
      }
      final listsJson = prefs.getString(_listsKey);

      if (listsJson != null) {
        final List<dynamic> decoded = jsonDecode(listsJson);
        _lists = decoded
            .map((e) => FilterList.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } else {
        // First run: add default lists (disabled until downloaded)
        _lists = _defaultLists
            .map((d) => FilterList(
                  id: d['id']!,
                  name: d['name']!,
                  url: d['url']!,
                ))
            .toList();
        await _saveLists();
      }

      // Parse cached filter text for enabled lists
      await _rebuildRules();

      LogService.instance.log('ContentBlocker',
          'Initialized: ${_lists.length} lists, '
          '${_blockedDomains.length} blocked domains, '
          '${_cosmeticSelectors.values.fold<int>(0, (s, l) => s + l.length)} cosmetic selectors',
          level: LogLevel.info);
    } catch (e) {
      LogService.instance.log('ContentBlocker', 'Error initializing: $e', level: LogLevel.error);
    }
  }

  /// Download a filter list by ID. Returns true on success.
  Future<bool> downloadList(String id) async {
    final list = _lists.firstWhere((l) => l.id == id,
        orElse: () => throw Exception('List not found: $id'));

    final clientResult = outboundHttp.clientFor(GlobalOutboundProxy.current);
    if (clientResult is OutboundClientBlocked) {
      LogService.instance.log(
        'ContentBlocker',
        'Skipped download of ${list.name}: ${clientResult.reason}',
        level: LogLevel.warning,
      );
      return false;
    }
    final client = (clientResult as OutboundClientReady).client;

    try {
      final response = await client
          .get(Uri.parse(list.url))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        LogService.instance.log('ContentBlocker', 'Download failed for ${list.name}: HTTP ${response.statusCode}', level: LogLevel.error);
        return false;
      }

      // Cache raw text to disk
      final cacheFile = await _getCacheFile(id);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString(response.body);

      // Parse
      final result = await parseAbpFilterList(response.body);

      list.ruleCount = result.convertedCount;
      list.skippedCount = result.skippedCount;
      list.lastUpdated = DateTime.now();
      list.enabled = true;

      await _saveLists();
      await _rebuildRules();

      LogService.instance.log('ContentBlocker', 'Downloaded ${list.name}: ${result.convertedCount} rules, ${result.skippedCount} skipped', level: LogLevel.info);

      return true;
    } catch (e) {
      LogService.instance.log('ContentBlocker', 'Error downloading ${list.name}: $e', level: LogLevel.error);
      return false;
    } finally {
      client.close();
    }
  }

  /// Download all enabled lists. Returns number of successful downloads.
  Future<int> downloadAllLists() async {
    int success = 0;
    for (final list in _lists) {
      if (list.enabled) {
        if (await downloadList(list.id)) {
          success++;
        }
      }
    }
    return success;
  }

  /// Add a custom filter list. Returns the new list's ID.
  Future<String> addCustomList(String name, String url) async {
    final id =
        'custom_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    _lists.add(FilterList(id: id, name: name, url: url));
    await _saveLists();
    return id;
  }

  /// Remove a filter list by ID.
  Future<void> removeList(String id) async {
    _lists.removeWhere((l) => l.id == id);

    // Delete cached file
    try {
      final cacheFile = await _getCacheFile(id);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (_) {}

    await _saveLists();
    await _rebuildRules();
  }

  /// Toggle a filter list enabled/disabled.
  Future<void> toggleList(String id, bool enabled) async {
    final list = _lists.firstWhere((l) => l.id == id);
    list.enabled = enabled;
    await _saveLists();
    await _rebuildRules();
  }

  /// Rebuild aggregated rules from all enabled lists' cached files.
  Future<void> _rebuildRules() async {
    final allDomains = <String>{};
    final allExceptions = <String>{};
    final allDomainPaths = <String, List<DomainPathRule>>{};
    final allSelectors = <String, List<String>>{};
    final allStyleRules = <String, List<StyleRule>>{};
    final allTextRules = <String, List<TextHideRule>>{};

    for (final list in _lists) {
      if (!list.enabled) continue;

      try {
        final cacheFile = await _getCacheFile(list.id);
        if (!await cacheFile.exists()) continue;

        final text = await cacheFile.readAsString();
        final result = parseAbpFilterListSync(text);
        allDomains.addAll(result.blockedDomains);
        allExceptions.addAll(result.exceptionDomains);

        for (final entry in result.blockedDomainPaths.entries) {
          allDomainPaths.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }
        for (final entry in result.cosmeticSelectors.entries) {
          allSelectors.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }
        for (final entry in result.styleRules.entries) {
          allStyleRules.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }
        for (final entry in result.textHideRules.entries) {
          allTextRules.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }

        list.ruleCount = result.convertedCount;
        list.skippedCount = result.skippedCount;
      } catch (e) {
        LogService.instance.log('ContentBlocker', 'Error parsing cached list ${list.name}: $e', level: LogLevel.error);
      }
    }

    // Compile path globs once per rebuild — runtime path matching does
    // a per-domain RegExp.hasMatch on the URL's post-host portion.
    final compiledPaths = <String, List<RegExp>>{};
    for (final entry in allDomainPaths.entries) {
      compiledPaths[entry.key] =
          entry.value.map((r) => compileDomainPathGlob(r.pathGlob)).toList();
    }

    _blockedDomains = allDomains;
    _exceptionDomains = allExceptions;
    _blockedDomainPathRegexes = compiledPaths;
    _cosmeticSelectors = allSelectors;
    _styleRules = allStyleRules;
    _textHideRules = allTextRules;
    _isBlockedCache.clear();
    _engineCosmeticCache.clear();
    _maybeRebuildRustEngine();
    _notifyRulesChanged();
  }

  /// Rebuild the Rust engine from the same cached filter files the
  /// Dart engine consumes. No-op when [_rustEngineEnabled] is false
  /// or the native library is unavailable. Called from
  /// [_rebuildRules] so the engine and Dart aggregations stay in sync.
  Future<void> _maybeRebuildRustEngine() async {
    _rustEngine?.dispose();
    _rustEngine = null;
    // When the engine is off, also tear down the Android-side native
    // engine if any. Empty rules string = "engine off" on the Kotlin
    // side. Cheap no-op on non-Android.
    if (!_rustEngineEnabled) {
      if (Platform.isAndroid) {
        await WebInterceptNative.sendAdblockEngineRules('');
      }
      return;
    }
    final buf = StringBuffer();
    var listCount = 0;
    for (final list in _lists) {
      if (!list.enabled) continue;
      try {
        final cacheFile = await _getCacheFile(list.id);
        if (await cacheFile.exists()) {
          buf.writeln(await cacheFile.readAsString());
          listCount++;
        }
      } catch (_) {/* ignored — same-faith as the Dart parse path */}
    }
    if (buf.isEmpty) {
      LogService.instance.log('ContentBlocker',
          'Rust engine enabled but no enabled lists have cached files — '
          'engine remains uninstantiated.',
          level: LogLevel.warning);
      if (Platform.isAndroid) {
        await WebInterceptNative.sendAdblockEngineRules('');
      }
      return;
    }
    final sw = Stopwatch()..start();
    final engine = AdblockEngine.load(buf.toString());
    sw.stop();
    if (engine == null) {
      LogService.instance.log('ContentBlocker',
          'Rust engine flag is set but the library is not loadable on this platform — falling back to Dart engine.',
          level: LogLevel.warning);
      return;
    }
    _rustEngine = engine;
    LogService.instance.log('ContentBlocker',
        'Rust engine active: ${engine.version} '
        '(parsed $listCount list(s), ${buf.length} bytes, '
        '${sw.elapsedMilliseconds}ms)',
        level: LogLevel.info);
    if (Platform.isAndroid) {
      // Phase 9: also push the rules text to the native engine so
      // FastSubresourceInterceptor can consult it without a Dart
      // roundtrip per sub-resource. The native side spins up its
      // own engine instance from the same text — separate from the
      // Dart-side instance, but both are pure functions of the
      // rules so they always agree on decisions.
      final result =
          await WebInterceptNative.sendAdblockEngineRules(buf.toString());
      if (result == null || result['active'] != true) {
        LogService.instance.log('ContentBlocker',
            'Note: native adblock engine not active on this Android build '
            '(library missing or load failed). Sub-resources keep the '
            'host-only fast path seeded by the Dart parser; main-document '
            'navigation + cosmetic still flow through the Dart engine.',
            level: LogLevel.warning);
      } else {
        LogService.instance.log('ContentBlocker',
            'Native adblock-rust active for Android sub-resources too — '
            '\$domain= / path-anchored / resource-type rules now fire on '
            'every request, not just top-level nav.',
            level: LogLevel.info);
      }
    }
  }

  Future<void> _saveLists() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_lists.map((l) => l.toJson()).toList());
    await prefs.setString(_listsKey, json);
  }

  Future<File> _getCacheFile(String id) async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheDir/$id.txt');
  }

  /// Exposed for testing: reset singleton state.
  @visibleForTesting
  void reset() {
    _lists = [];
    _blockedDomains = {};
    _exceptionDomains = {};
    _blockedDomainPathRegexes = {};
    _cosmeticSelectors = {};
    _styleRules = {};
    _textHideRules = {};
    _isBlockedCache.clear();
    _rustEngine?.dispose();
    _rustEngine = null;
  }

  /// Exposed for testing: install a Rust engine directly without
  /// going through file I/O. Mirrors the post-rebuild state.
  @visibleForTesting
  void setRustEngineForTest(AdblockEngine? engine) {
    _rustEngine?.dispose();
    _rustEngine = engine;
  }

  /// Exposed for testing: seed path-anchored rules without going
  /// through file I/O. Mirrors the compiled-regex shape produced by
  /// [_rebuildRules].
  @visibleForTesting
  void setDomainPathRulesForTest(Map<String, List<String>> rulesByDomain) {
    final compiled = <String, List<RegExp>>{};
    for (final entry in rulesByDomain.entries) {
      compiled[entry.key.toLowerCase()] =
          entry.value.map(compileDomainPathGlob).toList();
    }
    _blockedDomainPathRegexes = compiled;
    _isBlockedCache.clear();
  }

  /// Exposed for testing: seed `:style()` rules.
  @visibleForTesting
  void setStyleRulesForTest(Map<String, List<StyleRule>> rules) {
    _styleRules = rules;
  }

  /// Exposed for testing: seed cosmetic selectors directly.
  @visibleForTesting
  void setCosmeticSelectorsForTest(Map<String, List<String>> selectors) {
    _cosmeticSelectors = selectors;
  }

  /// Exposed for testing: set lists directly.
  @visibleForTesting
  void setLists(List<FilterList> lists) {
    _lists = lists;
  }

  /// Exposed for testing: seed the aggregated blocked domains directly,
  /// bypassing the file I/O / parser path. Mirrors the shape produced
  /// by [_rebuildRules] so the [isBlocked] hot path can be exercised
  /// without staging cached filter files on disk.
  @visibleForTesting
  void setBlockedDomainsForTest(Set<String> domains) {
    _blockedDomains = domains;
    _isBlockedCache.clear();
  }

  /// Exposed for testing: set blocked domains directly.
  @visibleForTesting
  void setBlockedDomains(Set<String> domains) {
    _blockedDomains = domains;
    _isBlockedCache.clear();
  }

  /// Exposed for testing: set exception domains directly.
  @visibleForTesting
  void setExceptionDomains(Set<String> domains) {
    _exceptionDomains = domains;
    _isBlockedCache.clear();
  }
}

/// Per-page slice of the engine's cosmetic response we keep around
/// for the lifetime of one rebuild. Cached so the early-CSS shim,
/// the post-load cosmetic shim, and the generic-scanner exception
/// merge all share the same FFI roundtrip.
class _EngineCosmeticCache {
  final List<String> hides;
  final Set<String> exceptions;
  final bool genericHide;
  _EngineCosmeticCache({
    required this.hides,
    required this.exceptions,
    required this.genericHide,
  });
}
