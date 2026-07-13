import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:webspace/services/abp_network_hosts.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/bloom_filter.dart';
import 'package:webspace/services/content_blocker_shim.dart';
import 'package:webspace/services/host_lookup.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/procedural_action_backfill.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// Network blocking, cosmetic filtering, redirect/CSP/removeparam rule
/// evaluation all flow through Brave's adblock-rust via the [AdblockEngine]
/// FFI wrapper. The engine is unconditional: on platforms that ship the
/// native library it loads on first rebuild; on platforms that don't
/// (e.g. Windows is unsupported), all queries silently no-op.
class ContentBlockerService {
  static const String _listsKey = 'content_blocker_lists';
  static const String _cacheDir = 'content_blocker_cache';

  /// Bump when the rules-text preprocessing (procedural backfill
  /// rewrite, future similar transforms) changes its output, so a
  /// blob written under the old transform is rejected and the
  /// engine re-parses fresh. The constant becomes a cache-key
  /// prefix; the actual rules text still hashes into the key, so
  /// list-content changes are detected independently.
  static const int _kEngineCacheVersion = 2;

  static ContentBlockerService? _instance;
  static ContentBlockerService get instance =>
      _instance ??= ContentBlockerService._();

  ContentBlockerService._();

  List<FilterList> _lists = [];

  /// Hosts named by anchored `||host^` network-block rules in the loaded
  /// lists. Pushed to [DnsBlockService] so the iOS/macOS sub-resource
  /// interceptor's prefilter Bloom trips for ABP-only hosts instead of
  /// hard-allowing them on a bloom miss. Recomputed on every
  /// [_rebuildEngine]; empty when no engine/lists are active.
  Set<String> _abpNetworkHosts = <String>{};

  /// See [_abpNetworkHosts].
  Set<String> get abpNetworkBlockHosts => _abpNetworkHosts;

  /// Literal tokens of HOSTLESS network rules (path/substring), used to
  /// build [genericNetworkTokenBloom]. See abp_network_hosts.dart.
  Set<String> _genericNetworkTokens = <String>{};

  /// True when the loaded lists carry network rules we can't reduce to a
  /// guaranteed token (regex, or only sub-3-char runs). The JS
  /// interceptor must then round-trip on every host-Bloom miss.
  bool _hasUntokenizableNetworkRules = false;
  bool get hasUntokenizableNetworkRules => _hasUntokenizableNetworkRules;

  BloomFilter? _genericTokenBloom;

  /// Bloom over [_genericNetworkTokens] for the JS interceptor's
  /// hostless-rule prefilter. Null when no hostless tokenizable rules
  /// are loaded (the common case — the JS side then skips token checks).
  BloomFilter? get genericNetworkTokenBloom {
    if (_genericNetworkTokens.isEmpty) return null;
    return _genericTokenBloom ??=
        BloomFilter.build(_genericNetworkTokens, fpRate: 0.02);
  }

  /// Native engine that owns every blocking + cosmetic decision. Built
  /// lazily on the first [_rebuildEngine] call and disposed + rebuilt
  /// whenever the filter set changes (the underlying engine has no
  /// incremental update API).
  AdblockEngine? _rustEngine;

  /// True when the engine is loaded and parsing succeeded. Used by
  /// callers that need to gate engine-specific JS shims (generic
  /// cosmetic scanner, procedural runner) on the engine being live.
  bool get usingRustEngine => _rustEngine != null;

  /// Whether the platform actually ships the engine library. UI bindings
  /// can use this to surface "no adblock on this platform" diagnostics.
  /// Cheap to call: the `DynamicLibrary.open` probe runs once and caches.
  bool get rustEngineSupportedOnPlatform {
    if (_rustEngineSupported != null) return _rustEngineSupported!;
    if (Platform.isAndroid) {
      return _rustEngineSupported ?? false;
    }
    final probe = AdblockEngine.load('');
    _rustEngineSupported = probe != null;
    probe?.dispose();
    return _rustEngineSupported!;
  }
  bool? _rustEngineSupported;

  // ---- DevTools: per-request engine timing ----

  static const int _engineDecisionBuffer = 200;
  final List<EngineDecisionSample> _recentEngineDecisions = [];
  bool _engineTimingEnabled = true;

  int _engineConsultedSinceTimingOn = 0;
  int _engineBlockedSinceTimingOn = 0;
  int _engineAllowedSinceTimingOn = 0;

  int get engineConsultedSinceTimingOn => _engineConsultedSinceTimingOn;

  /// Cumulative block/allow tallies since timing was (re-)enabled. Unlike
  /// [recentEngineDecisions] these don't decay when the sample ring
  /// rolls over, so the DevTools ABP tab shows true totals.
  int get engineBlockedSinceTimingOn => _engineBlockedSinceTimingOn;
  int get engineAllowedSinceTimingOn => _engineAllowedSinceTimingOn;

  set engineTimingEnabled(bool v) {
    if (_engineTimingEnabled == v) return;
    _engineTimingEnabled = v;
    if (!v) {
      _recentEngineDecisions.clear();
    } else {
      _engineConsultedSinceTimingOn = 0;
      _engineBlockedSinceTimingOn = 0;
      _engineAllowedSinceTimingOn = 0;
    }
    LogService.instance.log('ContentBlocker',
        'engine timing recording: ${v ? "ON" : "OFF"} '
        '(engineActive=${_rustEngine != null})',
        level: LogLevel.info);
  }
  bool get engineTimingEnabled => _engineTimingEnabled;

  List<EngineDecisionSample> get recentEngineDecisions =>
      List.unmodifiable(_recentEngineDecisions);

  /// [count] folds N deduped repeats of the same decision into the
  /// counters while adding a single sample row. [micros] is null for
  /// decisions made outside this isolate (Android native engine) where
  /// no timing is available.
  void _recordEngineDecision(
      String url, String requestType, int? micros, bool blocked,
      {int count = 1}) {
    if (count < 1) count = 1;
    _engineConsultedSinceTimingOn += count;
    if (blocked) {
      _engineBlockedSinceTimingOn += count;
    } else {
      _engineAllowedSinceTimingOn += count;
    }
    if (_recentEngineDecisions.length >= _engineDecisionBuffer) {
      _recentEngineDecisions.removeAt(0);
    }
    _recentEngineDecisions.add(EngineDecisionSample(
      url: url,
      requestType: requestType,
      micros: micros,
      blocked: blocked,
      timestamp: DateTime.now(),
    ));
  }

  /// Fold a block decision made by the Android native JNI engine into
  /// the DevTools counters. The native interceptor dedupes by host and
  /// reports repeat requests via [count]; timing never crosses the
  /// bridge, so the sample carries no micros. Allowed native requests
  /// aren't attributable to the engine (the drain events don't say
  /// whether the engine was consulted), so only blocks are folded in;
  /// the Allowed tally is a Dart-side lower bound on Android.
  void recordNativeEngineBlock(String host, {int count = 1}) {
    if (!_engineTimingEnabled) return;
    _recordEngineDecision(host, 'native', null, true, count: count);
  }

  /// Whether uBO web_accessible_resources/ is wired into the engine.
  /// Drives the `$redirect=` rule output: when on, the engine returns
  /// the matching stub body (noop.js, 1x1.gif, …); when off, redirect
  /// rules become plain blocks (drop the request).
  bool get useUboResources => _useUboResources;
  bool _useUboResources = true;

  Future<void> setUseUboResources(bool enabled) async {
    if (_useUboResources == enabled) return;
    LogService.instance.log('ContentBlocker',
        'uBO resources toggle flipped to $enabled (was ${!enabled})',
        level: LogLevel.info);
    _useUboResources = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kUseUboResourcesKey, enabled);
    await _clearEngineCache();
    await _rebuildEngine();
  }

  /// All configured filter lists.
  List<FilterList> get lists => List.unmodifiable(_lists);

  /// Total rule count across all enabled lists.
  int get totalRuleCount =>
      _lists.where((l) => l.enabled).fold(0, (sum, l) => sum + l.ruleCount);

  /// Whether the engine is loaded and ready to answer queries.
  bool get hasRules => _rustEngine != null;

  /// Listeners invoked when the engine is rebuilt (download, toggle,
  /// remove, re-init). main.dart uses this to invalidate caches that
  /// depend on the rule set.
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

  /// `$redirect=` lookup. Returns the redirect target as a `data:` URL
  /// when a matching rule fires, or null otherwise.
  String? redirectFor(
    String url, {
    String sourceUrl = '',
    String requestType = 'other',
  }) {
    final engine = _rustEngine;
    if (engine == null) return null;
    return engine.redirectFor(
      url,
      sourceUrl: sourceUrl,
      requestType: requestType,
    );
  }

  /// `$removeparam=` lookup. Returns the URL after the engine strips
  /// matching query keys. Null when no rewrite applies.
  String? rewrittenUrl(
    String url, {
    String sourceUrl = '',
    String requestType = 'other',
  }) {
    final engine = _rustEngine;
    if (engine == null) return null;
    return engine.rewrittenUrl(
      url,
      sourceUrl: sourceUrl,
      requestType: requestType,
    );
  }

  /// Procedural cosmetic actions (uBO's `:has-text()`, `:upward(N)`,
  /// `:remove()`, etc.) for [pageUrl] as raw adblock-rust JSON strings.
  List<String> proceduralActionsFor(String pageUrl) {
    final ctx = _engineCosmeticFor(pageUrl);
    if (ctx == null) return const [];
    return ctx.proceduralActions;
  }

  /// Snapshot of the cosmetic engine's readiness for a diagnostic
  /// readout (the ABP rule probe). Reports whether the engine is loaded
  /// at all, how many hide/procedural rules it resolves for [pageUrl]
  /// (via the same hostless-scheme normalization the real injection
  /// uses), and which of the caller-supplied [canaryClasses] the engine
  /// would hide — a non-empty hit means the filter list that defines
  /// those classes is actually loaded, distinguishing "no cosmetic list
  /// loaded" from "rules loaded but not firing".
  Map<String, dynamic> cosmeticDiagnostics(
    String pageUrl, {
    Set<String> canaryClasses = const <String>{},
  }) {
    final engine = _rustEngine;
    if (engine == null) {
      return {
        'engineActive': false,
        'pageHideCount': 0,
        'pageProceduralCount': 0,
        'canaryHits': const <String>[],
      };
    }
    final ctx = _engineCosmeticFor(pageUrl);
    final hits = canaryClasses.isEmpty
        ? const <String>[]
        : engine
            .hiddenClassIdSelectors(canaryClasses, const <String>{})
            .toList();
    return {
      'engineActive': true,
      'pageHideCount': ctx?.hides.length ?? 0,
      'pageProceduralCount': ctx?.proceduralActions.length ?? 0,
      'canaryHits': hits,
    };
  }

  /// `$csp=` lookup. Returns joined Content-Security-Policy directives
  /// for matching rules at this URL.
  String? cspFor(
    String url, {
    String sourceUrl = '',
    String requestType = 'other',
  }) {
    final engine = _rustEngine;
    if (engine == null) return null;
    return engine.cspFor(
      url,
      sourceUrl: sourceUrl,
      requestType: requestType,
    );
  }

  bool isBlocked(
    String url, {
    String sourceUrl = '',
    String requestType = 'other',
  }) {
    final engine = _rustEngine;
    if (engine == null) return false;
    if (_engineTimingEnabled) {
      final sw = Stopwatch()..start();
      final blocked = engine.shouldBlock(
        url,
        sourceUrl: sourceUrl,
        requestType: requestType,
      );
      sw.stop();
      _recordEngineDecision(url, requestType, sw.elapsedMicroseconds, blocked);
      return blocked;
    }
    return engine.shouldBlock(
      url,
      sourceUrl: sourceUrl,
      requestType: requestType,
    );
  }

  /// Whether a request to the root of [host] would be blocked. Used by
  /// the iOS/macOS PerformanceObserver bridge for the per-host stats
  /// attribution path. Engine-only — synthesises an `https://<host>/`
  /// URL and asks the engine; matches the semantics of plain
  /// `||domain^` rules.
  bool isHostBlocked(String host) {
    final engine = _rustEngine;
    if (engine == null || host.isEmpty) return false;
    final url = 'https://$host/';
    if (_engineTimingEnabled) {
      final sw = Stopwatch()..start();
      final blocked = engine.shouldBlock(url);
      sw.stop();
      _recordEngineDecision(url, 'host', sw.elapsedMicroseconds, blocked);
      return blocked;
    }
    return engine.shouldBlock(url);
  }

  /// Normalize the page URL before passing it to the engine's
  /// `cosmeticResources(url)`. adblock-rust's
  /// `Engine::url_cosmetic_resources` internally constructs a `Request`
  /// from the URL and returns an empty `UrlSpecificResources` when that
  /// construction fails — which it does for any URL without a real
  /// hostname (file://, blob:, data:, about:). The misc-generic-selector
  /// merge (attribute selectors, :has(), :style(), procedural shapes)
  /// happens *inside* `hostname_cosmetic_resources`, downstream of that
  /// early-return, so all of those rule shapes silently miss on these
  /// schemes.
  ///
  /// Substitute a sentinel `https://` host so the engine parses the
  /// URL, runs the generic merge, and returns the rules. The hostname
  /// has to be one no real filter list would target — `.invalid` is
  /// reserved by RFC 6761 for exactly this purpose.
  String _engineQueryUrl(String pageUrl) {
    const hostlessSchemes = ['file:', 'blob:', 'data:', 'about:'];
    for (final scheme in hostlessSchemes) {
      if (pageUrl.startsWith(scheme)) {
        return 'https://webspace.invalid/';
      }
    }
    return pageUrl;
  }

  /// Cached engine cosmetic result per page URL within one rebuild
  /// window. The engine call is non-trivial (JSON marshal across FFI)
  /// and we hit it multiple times per page (early-CSS + post-load
  /// cosmetic + procedural + generic scanner). Cleared in
  /// [_rebuildEngine].
  final Map<String, _EngineCosmeticCache> _engineCosmeticCache = {};

  _EngineCosmeticCache? _engineCosmeticFor(String pageUrl) {
    final engine = _rustEngine;
    if (engine == null) return null;
    final cached = _engineCosmeticCache[pageUrl];
    if (cached != null) return cached;
    final effectiveUrl = _engineQueryUrl(pageUrl);
    final raw = engine.cosmeticResources(effectiveUrl);
    if (raw == null) return null;
    final hides = (raw['hide_selectors'] as List? ?? const [])
        .cast<String>()
        .toList();
    final exceptions = (raw['exceptions'] as List? ?? const [])
        .cast<String>()
        .toSet();
    final genericHide = raw['generichide'] == true;
    final procedural = (raw['procedural_actions'] as List? ?? const [])
        .cast<String>()
        .toList();
    // Union in the procedural rules our filter-list rewrite anchored
    // to the synthetic host. Skip when the effective URL already
    // matches that host (file:// → kBackfillSyntheticHost path), the
    // first call covers it. Hides + exceptions from the synthetic
    // query are intentionally discarded — the real-URL query already
    // produced them via the misc-generic-selector merge.
    if (!effectiveUrl.contains('://$kBackfillSyntheticHost')) {
      final synth = engine
          .cosmeticResources('https://$kBackfillSyntheticHost/');
      if (synth != null) {
        final synthProc = (synth['procedural_actions'] as List? ?? const [])
            .cast<String>();
        procedural.addAll(synthProc);
      }
    }
    final entry = _EngineCosmeticCache(
      hides: hides,
      exceptions: exceptions,
      genericHide: genericHide,
      proceduralActions: procedural,
    );
    _engineCosmeticCache[pageUrl] = entry;
    LogService.instance.log('ContentBlocker',
        'engine.cosmeticResources($pageUrl) → '
        '${hides.length} hide(s), ${exceptions.length} exception(s)'
        '${genericHide ? ", generichide" : ""}'
        '${procedural.isNotEmpty ? ", ${procedural.length} procedural" : ""}',
        level: LogLevel.debug,
        sensitivity: LogSensitivity.sensitive);
    return entry;
  }

  /// Get CSS-only JavaScript for early injection at DOCUMENT_START.
  /// Injects a <style> tag with display:none rules before content
  /// renders. Returns null if the engine has no domain-scoped hides
  /// for this URL.
  String? getEarlyCssScript(String pageUrl) {
    final ctx = _engineCosmeticFor(pageUrl);
    if (ctx == null) return null;
    final script = buildContentBlockerEarlyCssShim(
      selectors: ctx.hides,
      styleRules: const [],
    );
    LogService.instance.log(
        'ContentBlocker',
        'getEarlyCssScript($pageUrl): '
        '${ctx.hides.length} hide(s) '
        '→ ${script == null ? "no script" : "${script.length} bytes"}',
        level: LogLevel.debug,
        sensitivity: LogSensitivity.sensitive);
    return script;
  }

  /// Generic class/id-targeted selectors from the engine. Driven by the
  /// page-side scanner shim which dumps unique classes + ids and calls
  /// back through the `genericCosmeticScan` bridge handler.
  ///
  /// Returns empty when the engine isn't active, no scan-input was
  /// supplied, or the page has `$generichide` allowlisted.
  List<String> genericCosmeticSelectorsFor({
    required String pageUrl,
    required Set<String> classes,
    required Set<String> ids,
    Set<String> exceptions = const <String>{},
  }) {
    final engine = _rustEngine;
    if (engine == null) return const [];
    if (classes.isEmpty && ids.isEmpty) return const [];
    final engineCtx = _engineCosmeticFor(pageUrl);
    if (engineCtx?.genericHide == true) {
      LogService.instance.log('ContentBlocker',
          'engine.hiddenClassIdSelectors($pageUrl) skipped — '
          'page has \$generichide allowlist',
          level: LogLevel.debug,
          sensitivity: LogSensitivity.sensitive);
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
        level: LogLevel.debug,
        sensitivity: LogSensitivity.sensitive);
    return result;
  }

  /// Get full JavaScript for injection after page load. Same <style>
  /// tag as the early shim — text-content rules and `:style()` rules
  /// flow through the procedural runner now that adblock-rust owns the
  /// cosmetic side.
  String? getCosmeticScript(String pageUrl) {
    final ctx = _engineCosmeticFor(pageUrl);
    if (ctx == null) return null;
    return buildContentBlockerCosmeticShim(
      selectors: ctx.hides,
      styleRules: const [],
      textRules: const [],
    );
  }

  /// Initialize: load list metadata from prefs, parse cached files for
  /// enabled lists. Idempotent.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _useUboResources = prefs.getBool(kUseUboResourcesKey) ?? true;
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
        _lists = _defaultLists
            .map((d) => FilterList(
                  id: d['id']!,
                  name: d['name']!,
                  url: d['url']!,
                ))
            .toList();
        await _saveLists();
      }

      await _rebuildEngine();

      LogService.instance.log('ContentBlocker',
          'Initialized: ${_lists.length} list(s), engine '
          '${_rustEngine == null ? "inactive" : "active"}',
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

      final cacheFile = await _getCacheFile(id);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString(response.body);

      // adblock-rust counts rules at parse time inside the engine — we
      // don't have a parse-only API on this side, so the displayed
      // ruleCount becomes a coarse proxy (line count of the raw list,
      // including comments). Better than the previous Dart parser's
      // per-rule count, which had its own classification quirks.
      list.ruleCount = _approximateRuleCount(response.body);
      list.skippedCount = 0;
      list.lastUpdated = DateTime.now();
      list.enabled = true;

      await _saveLists();
      await _rebuildEngine();

      LogService.instance.log('ContentBlocker', 'Downloaded ${list.name}: ~${list.ruleCount} rules', level: LogLevel.info);

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

    try {
      final cacheFile = await _getCacheFile(id);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (_) {}

    await _saveLists();
    await _rebuildEngine();
  }

  /// Toggle a filter list enabled/disabled.
  Future<void> toggleList(String id, bool enabled) async {
    final list = _lists.firstWhere((l) => l.id == id);
    list.enabled = enabled;
    await _saveLists();
    await _rebuildEngine();
  }

  /// Rebuild the engine from cached filter files. The engine has no
  /// incremental update API, so each rebuild tears down + parses fresh
  /// (or deserializes from the on-disk cache when the rule hash
  /// matches).
  Future<void> _rebuildEngine() async {
    _rustEngine?.dispose();
    _rustEngine = null;
    _engineCosmeticCache.clear();

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
      } catch (_) {}
    }
    final concatenated = buf.toString();
    // Harvest interceptor prefilter inputs (`||host^` hosts + hostless
    // rule tokens) before the procedural rewrite, which only touches
    // cosmetic lines. Listeners push the hosts to DnsBlockService on
    // _notifyRulesChanged; the token bloom rides the getBlockBloom map.
    final prefilter = parseAbpNetworkPrefilter(concatenated);
    _abpNetworkHosts = prefilter.hosts;
    _genericNetworkTokens = prefilter.tokens;
    _hasUntokenizableNetworkRules = prefilter.hasUntokenizable;
    _genericTokenBloom = null;
    if (buf.isEmpty) {
      if (Platform.isAndroid) {
        await WebInterceptNative.sendAdblockEngineRules('');
      }
      _notifyRulesChanged();
      return;
    }
    // Rewrite generic procedural rules with a synthetic-host prefix
    // so adblock-rust's parser stores them as domain-scoped (it would
    // otherwise drop them at parse time — see
    // procedural_action_backfill.dart). The rewritten text is what
    // the engine sees and what the cache key is computed over; bump
    // [_kEngineCacheVersion] when the rewrite output format changes
    // so old cached blobs get re-parsed.
    final rulesText = rewriteGenericProceduralsForBackfill(concatenated);
    final rulesHash =
        sha256.convert(utf8.encode('v$_kEngineCacheVersion:$rulesText')).toString();
    AdblockEngine? engine;
    String loadMode = 'parse';
    final sw = Stopwatch()..start();

    final cached = await _readEngineCache(rulesHash);
    if (cached != null) {
      engine = AdblockEngine.loadFromSerialized(cached,
          enableUboResources: _useUboResources);
      if (engine != null) {
        loadMode = 'deserialize';
      } else {
        await _clearEngineCache();
      }
    }
    engine ??= AdblockEngine.load(rulesText,
        enableUboResources: _useUboResources);
    sw.stop();
    if (engine == null) {
      LogService.instance.log('ContentBlocker',
          'Engine library is not loadable on this platform — '
          'adblock decisions will all return "allowed".',
          level: LogLevel.warning);
      if (Platform.isAndroid) {
        await WebInterceptNative.sendAdblockEngineRules('');
      }
      _notifyRulesChanged();
      return;
    }
    _rustEngine = engine;
    LogService.instance.log('ContentBlocker',
        'Engine active: ${engine.version} '
        '($loadMode $listCount list(s), ${rulesText.length} bytes, '
        '${sw.elapsedMilliseconds}ms)',
        level: LogLevel.info);
    if (loadMode == 'parse') {
      unawaited(_writeEngineCache(rulesHash, engine));
    }
    if (Platform.isAndroid) {
      final result =
          await WebInterceptNative.sendAdblockEngineRules(rulesText,
              enableUboResources: _useUboResources);
      if (result == null || result['active'] != true) {
        LogService.instance.log('ContentBlocker',
            'Native engine inactive on this Android build — '
            'sub-resource blocking will Dart-roundtrip per request.',
            level: LogLevel.warning);
      } else {
        LogService.instance.log('ContentBlocker',
            'Native engine active for Android sub-resources.',
            level: LogLevel.info);
      }
    }
    _notifyRulesChanged();
  }

  /// Coarse line count of the raw filter list, used only for the
  /// settings UI's "~N rules" subtitle. adblock-rust does the real
  /// classification at engine-parse time and doesn't expose it.
  int _approximateRuleCount(String text) {
    var count = 0;
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('!')) continue;
      if (trimmed.startsWith('[')) continue;
      count++;
    }
    return count;
  }

  /// User-intent slice of the filter-list configuration for settings
  /// export: which lists exist, their source URLs, and whether they're
  /// enabled. Download-side metadata (rule counts, last-updated, skipped
  /// counts) is deliberately omitted — it's machine state tied to a blob
  /// the backup doesn't carry. See content-blocker spec CB-011.
  List<Map<String, dynamic>> exportListSelection() => _lists
      .map((l) => <String, dynamic>{
            'id': l.id,
            'name': l.name,
            'url': l.url,
            'enabled': l.enabled,
          })
      .toList();

  /// Restore a filter-list selection from a settings backup. Replaces the
  /// current list set with the imported one and rebuilds the engine.
  ///
  /// Download metadata is unknown until the user re-downloads, except
  /// where an imported id matches a list that was already present (its
  /// cache file may still be on disk): the prior counts/timestamp are
  /// kept so the engine rebuild reuses the existing blob and the UI shows
  /// accurate counts without a re-download. Entries missing id/name/url
  /// are skipped.
  Future<void> importListSelection(List<Map<String, dynamic>> entries) async {
    final priorById = {for (final l in _lists) l.id: l};
    final restored = <FilterList>[];
    for (final e in entries) {
      final id = e['id'] as String?;
      final name = e['name'] as String?;
      final url = e['url'] as String?;
      if (id == null || name == null || url == null) continue;
      final prior = priorById[id];
      restored.add(FilterList(
        id: id,
        name: name,
        url: url,
        enabled: e['enabled'] == true,
        ruleCount: prior?.ruleCount ?? 0,
        skippedCount: prior?.skippedCount ?? 0,
        lastUpdated: prior?.lastUpdated,
      ));
    }
    _lists = restored;
    await _saveLists();
    await _rebuildEngine();
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

  Future<File> _engineCacheFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheDir/.engine.bin');
  }

  Future<File> _engineCacheMetaFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheDir/.engine.meta');
  }

  Future<Uint8List?> _readEngineCache(String expectedHash) async {
    try {
      final meta = await _engineCacheMetaFile();
      if (!await meta.exists()) return null;
      final metaText = await meta.readAsString();
      final parts = metaText.split(':');
      if (parts.length != 2) return null;
      if (parts[0] != expectedHash) return null;
      if ((parts[1] == '1') != _useUboResources) return null;
      final bin = await _engineCacheFile();
      if (!await bin.exists()) return null;
      return await bin.readAsBytes();
    } catch (e) {
      LogService.instance.log('ContentBlocker',
          'engine cache read failed: $e — falling back to parse',
          level: LogLevel.debug);
      return null;
    }
  }

  Future<void> _writeEngineCache(String hash, AdblockEngine engine) async {
    try {
      final blob = engine.serialize();
      if (blob == null) return;
      final bin = await _engineCacheFile();
      await bin.parent.create(recursive: true);
      await bin.writeAsBytes(blob, flush: true);
      final meta = await _engineCacheMetaFile();
      await meta.writeAsString('$hash:${_useUboResources ? '1' : '0'}');
      LogService.instance.log('ContentBlocker',
          'engine cache written: ${blob.length} bytes (hash=${hash.substring(0, 8)}…)',
          level: LogLevel.debug);
    } catch (e) {
      LogService.instance.log('ContentBlocker',
          'engine cache write failed: $e',
          level: LogLevel.warning);
    }
  }

  Future<void> _clearEngineCache() async {
    try {
      final bin = await _engineCacheFile();
      if (await bin.exists()) await bin.delete();
      final meta = await _engineCacheMetaFile();
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }

  /// Exposed for testing: reset singleton state.
  @visibleForTesting
  void reset() {
    _lists = [];
    _rustEngine?.dispose();
    _rustEngine = null;
    _engineCosmeticCache.clear();
    _recentEngineDecisions.clear();
    _engineTimingEnabled = true;
    _engineConsultedSinceTimingOn = 0;
    _engineBlockedSinceTimingOn = 0;
    _engineAllowedSinceTimingOn = 0;
    _abpNetworkHosts = <String>{};
    _genericNetworkTokens = <String>{};
    _hasUntokenizableNetworkRules = false;
    _genericTokenBloom = null;
    _useUboResources = true;
  }

  /// Exposed for testing: install an engine directly without going
  /// through file I/O.
  @visibleForTesting
  void setRustEngineForTest(AdblockEngine? engine) {
    _rustEngine?.dispose();
    _rustEngine = engine;
    _engineCosmeticCache.clear();
  }

  /// Exposed for testing: seed lists directly.
  @visibleForTesting
  void setLists(List<FilterList> lists) {
    _lists = lists;
  }
}

/// One row in [ContentBlockerService.recentEngineDecisions] — what the
/// engine answered for one sub-resource check, how long it took, when.
class EngineDecisionSample {
  final String url;
  final String requestType;

  /// Engine call duration; null for decisions made outside this isolate
  /// (Android native engine) where timing isn't reported.
  final int? micros;
  final bool blocked;
  final DateTime timestamp;
  const EngineDecisionSample({
    required this.url,
    required this.requestType,
    required this.micros,
    required this.blocked,
    required this.timestamp,
  });
}

class _EngineCosmeticCache {
  final List<String> hides;
  final Set<String> exceptions;
  final bool genericHide;
  final List<String> proceduralActions;
  _EngineCosmeticCache({
    required this.hides,
    required this.exceptions,
    required this.genericHide,
    required this.proceduralActions,
  });
}
