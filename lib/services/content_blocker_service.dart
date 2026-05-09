import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_shim.dart';
import 'package:webspace/services/host_lookup.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/services/log_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'abp_filter_parser.dart';
import 'abp_filter_parser_async.dart';

/// Compile-time switch: route network-block decisions through the
/// Rust-backed [AdblockEngine] when the platform ships the library.
/// The Dart parser-based engine remains the canonical path for
/// cosmetic rules until phase 4 wires those through too.
///
/// Build with `--dart-define=WEBSPACE_USE_RUST_ENGINE=1` to opt in.
/// When false, the service behaves exactly as before. When true and
/// the library can't be loaded (unsupported platform, missing .so),
/// the service silently falls back to the Dart path — the engine is
/// strictly an accelerator for the network side, never a precondition.
const bool kUseRustEngineForNetwork = bool.fromEnvironment(
  'WEBSPACE_USE_RUST_ENGINE',
  defaultValue: false,
);

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
  /// the build flag is on, the library loaded, and parsing succeeded.
  /// Tested via [usingRustEngine] for diagnostics + tests.
  bool get usingRustEngine => _rustEngine != null;

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
  bool isBlocked(String url) {
    // Rust engine takes precedence when active. It gives correct
    // answers for everything the Dart engine handles AND for $domain=
    // / regex / resource-type rules the Dart engine drops on the
    // floor. The Dart aggregations (`_blockedDomains` etc.) are still
    // populated so [isHostBlocked] (host-only fast path used by the
    // PerformanceObserver report) keeps working.
    final engine = _rustEngine;
    if (engine != null) {
      // No source URL plumbed through this entry point yet — the
      // engine treats empty source as "unknown", matching the Dart
      // engine's host-only semantics.
      return engine.shouldBlock(url);
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

  /// Collect applicable selectors, style rules, and text rules for a
  /// page URL.
  ({
    List<String> selectors,
    List<StyleRule> styleRules,
    List<TextHideRule> textRules,
  }) _collectRules(String pageUrl) {
    final selectors = <String>[];
    final styleRules = <StyleRule>[];
    final textRules = <TextHideRule>[];

    final globalSel = _cosmeticSelectors[''];
    if (globalSel != null) selectors.addAll(globalSel);
    final globalStyle = _styleRules[''];
    if (globalStyle != null) styleRules.addAll(globalStyle);
    final globalText = _textHideRules[''];
    if (globalText != null) textRules.addAll(globalText);

    final host = extractHost(pageUrl);
    if (host != null && host.isNotEmpty) {
      String domain = host;
      while (domain.isNotEmpty) {
        final ds = _cosmeticSelectors[domain];
        if (ds != null) selectors.addAll(ds);
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
    _maybeRebuildRustEngine();
    _notifyRulesChanged();
  }

  /// Rebuild the Rust engine from the same cached filter files the
  /// Dart engine consumes. No-op when [kUseRustEngineForNetwork] is
  /// false or the native library is unavailable. Called from
  /// [_rebuildRules] so the engine and Dart aggregations stay in sync.
  Future<void> _maybeRebuildRustEngine() async {
    _rustEngine?.dispose();
    _rustEngine = null;
    if (!kUseRustEngineForNetwork) return;
    final buf = StringBuffer();
    for (final list in _lists) {
      if (!list.enabled) continue;
      try {
        final cacheFile = await _getCacheFile(list.id);
        if (await cacheFile.exists()) {
          buf.writeln(await cacheFile.readAsString());
        }
      } catch (_) {/* ignored — same-faith as the Dart parse path */}
    }
    if (buf.isEmpty) return;
    final engine = AdblockEngine.load(buf.toString());
    if (engine == null) {
      LogService.instance.log('ContentBlocker',
          'Rust engine flag is set but the library is not loadable on this platform — falling back to Dart engine.',
          level: LogLevel.warning);
      return;
    }
    _rustEngine = engine;
    LogService.instance.log('ContentBlocker',
        'Rust engine active: ${engine.version}',
        level: LogLevel.info);
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
