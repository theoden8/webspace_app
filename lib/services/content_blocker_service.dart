import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
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

  /// Aggregated uBO procedural action rules (`:remove()`,
  /// `:remove-attr(...)`, `:remove-class(...)`): domain -> rules.
  /// Backfills for adblock-rust which drops every generic procedural
  /// rule at parse time (see `cosmetic_filter_cache_builder.rs:106`),
  /// so these fire on `file://` and other URLs where the engine's
  /// hostname-keyed procedural bucket is empty.
  Map<String, List<ProceduralActionRule>> _proceduralActions = {};

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

  // ---- DevTools: per-request engine timing ----
  //
  // Ring buffer of recent engine decisions. Off by default (the
  // Stopwatch overhead is small but non-zero, and the buffer write
  // is wasted bytes when no one's looking). DevTools flips
  // [engineTimingEnabled] on entry to the ABP tab and off on exit;
  // observers also bump a notify counter so the tab can rebuild.

  static const int _engineDecisionBuffer = 200;
  final List<EngineDecisionSample> _recentEngineDecisions = [];
  bool _engineTimingEnabled = false;

  /// Toggle per-request engine timing capture. When false, [isBlocked]
  /// skips the Stopwatch + buffer write — no overhead. DevTools turns
  /// this on while its ABP tab is visible.
  set engineTimingEnabled(bool v) {
    if (_engineTimingEnabled == v) return;
    _engineTimingEnabled = v;
    if (!v) _recentEngineDecisions.clear();
  }
  bool get engineTimingEnabled => _engineTimingEnabled;

  /// Last [_engineDecisionBuffer] decisions, newest last. Empty when
  /// timing is disabled or the engine hasn't decided yet.
  List<EngineDecisionSample> get recentEngineDecisions =>
      List.unmodifiable(_recentEngineDecisions);

  void _recordEngineDecision(
      String url, String requestType, int micros, bool blocked) {
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

  /// Whether uBO web_accessible_resources/ is wired into the engine.
  /// Drives the `$redirect=` rule output: when on, the engine returns
  /// the matching stub body (noop.js, 1x1.gif, …); when off, redirect
  /// rules become plain blocks (drop the request).
  bool get useUboResources => _useUboResources;
  bool _useUboResources = true;

  /// Persist + apply the uBO resources toggle. Rebuilds the engine so
  /// the change takes effect immediately. Hot, but the cost is the same
  /// as toggling the engine itself — single rebuild from cache files.
  Future<void> setUseUboResources(bool enabled) async {
    if (_useUboResources == enabled) return;
    LogService.instance.log('ContentBlocker',
        'uBO resources toggle flipped to $enabled (was ${!enabled})',
        level: LogLevel.info);
    _useUboResources = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kUseUboResourcesKey, enabled);
    if (_rustEngineEnabled) {
      // Sidecar invalidation handles this on the next read, but
      // doing it here too keeps the cache directory tidy.
      await _clearEngineCache();
      await _maybeRebuildRustEngine();
    }
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
  /// Engine-only lookup: when a `$redirect=` rule matches this
  /// request, returns the redirect target as a `data:` URL. Null
  /// when no redirect applies OR when the engine isn't active (the
  /// Dart parser doesn't support `$redirect=` rules; only the
  /// engine does).
  ///
  /// Called from the iOS/macOS JS bridge's `blockCheck` handler so
  /// the JS interceptor can swap the request URL with the data URL
  /// instead of dropping it. Android wires the same FFI symbol
  /// directly through JNI (`AdblockEngineNative.redirectFor`), so
  /// this Dart path is iOS/macOS/Linux-only — `AdblockEngine` is
  /// only loaded on those platforms.
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
  /// matching query keys. Null when no rewrite applies. Engine-only —
  /// the Dart parser doesn't handle this rule shape.
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
  /// Each entry parses into a tree the page-side shim walks.
  ///
  /// Two sources merged:
  ///   * Rust engine's `url_cosmetic_resources(url).procedural_actions`
  ///     — hostname-keyed; covers production filter lists that scope
  ///     procedural rules to specific sites.
  ///   * Dart parser's `_proceduralActions` map — captures the rule
  ///     shapes adblock-rust silently drops (every generic `##sel:
  ///     remove()` line, see `cosmetic_filter_cache_builder.rs:106`).
  ///     The Dart bucket fires on `file://` and any other URL where
  ///     the engine returns nothing.
  ///
  /// Empty list when both sources are silent.
  List<String> proceduralActionsFor(String pageUrl) {
    final out = <String>[];
    final ctx = _engineCosmeticFor(pageUrl);
    if (ctx != null) out.addAll(ctx.proceduralActions);

    // Globals — always apply (matches the rest of the Dart cosmetic
    // path which adds `_cosmeticSelectors['']` on top of engine
    // results).
    final globalProc = _proceduralActions[''];
    if (globalProc != null) {
      for (final r in globalProc) out.add(r.toEngineJson());
    }
    // Domain walk-up for hostname-scoped rules. Matches the same
    // pattern `_collectRules` uses for hides/styles/text-rules.
    final host = extractHost(pageUrl);
    if (host != null && host.isNotEmpty) {
      var domain = host;
      while (domain.isNotEmpty) {
        final scoped = _proceduralActions[domain];
        if (scoped != null) {
          for (final r in scoped) out.add(r.toEngineJson());
        }
        final dotIdx = domain.indexOf('.');
        if (dotIdx < 0) break;
        domain = domain.substring(dotIdx + 1);
      }
    }
    return out;
  }

  /// Apple-only: ruleset to hand WebKit via WKContentRuleListStore.
  /// Built once per engine rebuild from the Rust crate's content-blocking
  /// JSON export, cached as List<inapp.ContentBlocker>. WebKit caches the
  /// compiled list keyed by identifier across WebViews, so the per-
  /// WebView cost after the first compile is just a lookup.
  ///
  /// WebKit caps each ruleset at 50,000 rules. With production filter
  /// stacks (5 lists ≈ 200k rules) we'd blow the cap. Pragmatic trim:
  ///
  ///   1. Drop css-display-none rules. Native cosmetic via
  ///      WKContentRuleList fires no callback (no DevTools visibility,
  ///      no per-rule stat counter) and our early-CSS shim already
  ///      handles cosmetic — installing them natively too is pure
  ///      duplicate work.
  ///   2. If still > 50k, slice to the first 50k. The export's
  ///      ordering mirrors the input filter list, so the most-used
  ///      rules (canonical EasyList block lines at top of file) stay.
  ///      The dropped tail is also covered by the JS-bridge
  ///      `blockCheck` path.
  ///
  /// True chunking (up to 8 rulesets ≈ 400k rules) needs a fork patch
  /// to the plugin's contentBlockers setting, which currently only
  /// supports ONE compiled rule list per WebView. That's a follow-up.
  List<inapp.ContentBlocker> appleContentBlockers() {
    if (!Platform.isIOS && !Platform.isMacOS) return const [];
    if (!_rustEngineEnabled) return const [];
    final cached = _appleContentBlockersCache;
    if (cached != null) return cached;
    final aggregated = _aggregatedListsText;
    if (aggregated == null || aggregated.isEmpty) {
      _appleContentBlockersCache = const [];
      return const [];
    }
    final sw = Stopwatch()..start();
    final json =
        AdblockEngine.filterListToAppleContentBlockingJson(aggregated);
    sw.stop();
    if (json == null) {
      LogService.instance.log('ContentBlocker',
          'WKContentRuleList export failed — sub-resource blocking falls '
          'back to the JS bridge only',
          level: LogLevel.warning);
      _appleContentBlockersCache = const [];
      return const [];
    }
    final blockers = <inapp.ContentBlocker>[];
    var totalRaw = 0;
    var droppedCosmetic = 0;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) {
        _appleContentBlockersCache = const [];
        return const [];
      }
      totalRaw = decoded.length;
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final trigger = raw['trigger'];
        final action = raw['action'];
        if (trigger is! Map || action is! Map) continue;
        // Drop cosmetic — handled by the early-CSS shim already.
        if (action['type'] == 'css-display-none') {
          droppedCosmetic++;
          continue;
        }
        final triggerMap = Map<String, dynamic>.from(trigger);
        // ContentBlockerTrigger.fromMap reads `url-filter-is-case-
        // sensitive` without a null-default — passing it through
        // straight from adblock-rust (which omits the field) throws
        // "type 'Null' is not a subtype of type 'bool'". Pre-inject
        // the WKContentRuleList default so the parse succeeds.
        triggerMap.putIfAbsent('url-filter-is-case-sensitive', () => false);
        blockers.add(inapp.ContentBlocker.fromMap(
          {
            'trigger': triggerMap,
            'action': Map<String, dynamic>.from(action),
          },
          // EnumMethod.value: use the cross-platform identifier
          // ('block', 'css-display-none', etc. — exactly what
          // adblock-rust emits). `nativeValue` (the default) varies
          // by `defaultTargetPlatform`, which in flutter_test can
          // be a value none of the cases cover, returning null and
          // tripping the `!` in ContentBlockerAction.fromMap.
          enumMethod: inapp.EnumMethod.value,
        ));
      }
    } catch (e) {
      LogService.instance.log('ContentBlocker',
          'WKContentRuleList parse failed: $e',
          level: LogLevel.warning);
      _appleContentBlockersCache = const [];
      return const [];
    }
    // Trim to the cap if cosmetic-drop didn't get us under.
    final preSlice = blockers.length;
    if (blockers.length > 50000) {
      blockers.removeRange(50000, blockers.length);
    }
    LogService.instance.log(
      'ContentBlocker',
      'WKContentRuleList ready: ${blockers.length} rules '
      '(raw=$totalRaw, dropped cosmetic=$droppedCosmetic, '
      '${preSlice > blockers.length ? "sliced ${preSlice - blockers.length}, " : ""}'
      '${json.length} bytes JSON, ${sw.elapsedMilliseconds}ms export)',
      level: LogLevel.info,
    );
    _appleContentBlockersCache = List.unmodifiable(blockers);
    return _appleContentBlockersCache!;
  }

  List<inapp.ContentBlocker>? _appleContentBlockersCache;

  /// Concatenated filter-list text from the last engine rebuild. Set
  /// from `_maybeRebuildRustEngine` so [appleContentBlockers] can
  /// re-export without another async file-read pass. Null until the
  /// first rebuild; reset on every subsequent rebuild.
  String? _aggregatedListsText;

  /// `$csp=` lookup. Returns joined Content-Security-Policy directives
  /// for matching rules at this URL. Engine-only.
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
    if (engine != null) {
      // Time the engine call so DevTools can show per-request latency
      // distribution. Stopwatch overhead is ~50ns — negligible against
      // even a sub-microsecond engine hit. Skip when DevTools recording
      // is off (default) so production runs aren't paying for an empty
      // ring buffer write.
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
    final procedural = (raw['procedural_actions'] as List? ?? const [])
        .cast<String>()
        .toList();
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
        level: LogLevel.debug);
    return entry;
  }

  /// Collect applicable selectors, style rules, and text rules for a
  /// page URL.
  ///
  /// Cosmetic source-of-truth split:
  ///   * Generic rules (`##sel`, including pure attribute selectors
  ///     and compound selectors with `:has()`) come from the Dart
  ///     parser's `_cosmeticSelectors`. The engine's
  ///     `hidden_class_id_selectors` API only surfaces rules
  ///     indexed by class/id token — it CAN'T return
  ///     `##div[data-ad-slot]` (no class/id) and may not surface
  ///     `##div.article:has(...)` (compound). Letting the Dart
  ///     parser keep ownership of generic rules avoids that gap.
  ///   * Domain-scoped rules from the engine's `cosmeticResources`
  ///     are added ON TOP, contributing whatever extra adblock-rust
  ///     knows (e.g. `$style()` rules in `procedural_actions` once
  ///     we wire those through, exception handling, etc.).
  ///
  /// Net: when the engine is on, every Dart-parsed cosmetic still
  /// fires; the engine is purely additive. When the engine is off,
  /// only the Dart parser path runs. No regression in either mode.
  ({
    List<String> selectors,
    List<StyleRule> styleRules,
    List<TextHideRule> textRules,
  }) _collectRules(String pageUrl) {
    final selectors = <String>[];
    final styleRules = <StyleRule>[];
    final textRules = <TextHideRule>[];

    // Globals — always from Dart parser, regardless of engine state.
    // Catches attribute-only and compound generic selectors the
    // engine's class/id index can't surface.
    final globalSel = _cosmeticSelectors[''];
    if (globalSel != null) selectors.addAll(globalSel);
    final globalStyle = _styleRules[''];
    if (globalStyle != null) styleRules.addAll(globalStyle);
    final globalText = _textHideRules[''];
    if (globalText != null) textRules.addAll(globalText);

    // Engine's per-URL domain-scoped hides on top — only when the
    // engine is active. Cheap duplicate suppression by the CSS
    // engine, so we don't bother deduplicating Dart-side.
    final engineHides = _engineCosmeticFor(pageUrl);
    if (engineHides != null) {
      selectors.addAll(engineHides.hides);
    }

    final host = extractHost(pageUrl);
    if (host != null && host.isNotEmpty) {
      String domain = host;
      while (domain.isNotEmpty) {
        // Dart-parser domain walk-up always runs. Same rationale as
        // globals: ensures the parser's view of domain-scoped rules
        // isn't silently dropped when the engine is on. Engine's
        // domain-scoped rules came in via cosmeticResources(url) above.
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
    final script = buildContentBlockerEarlyCssShim(
      selectors: rules.selectors,
      styleRules: rules.styleRules
          .map((r) => (selector: r.selector, declarations: r.declarations))
          .toList(),
    );
    LogService.instance.log(
        'ContentBlocker',
        'getEarlyCssScript($pageUrl): '
        '${rules.selectors.length} hide(s), '
        '${rules.styleRules.length} :style() rule(s) '
        '→ ${script == null ? "no script" : "${script.length} bytes"}',
        level: LogLevel.debug);
    return script;
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
      _useUboResources = prefs.getBool(kUseUboResourcesKey) ?? true;
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
    final allProceduralActions = <String, List<ProceduralActionRule>>{};

    for (final list in _lists) {
      if (!list.enabled) continue;

      try {
        final cacheFile = await _getCacheFile(list.id);
        if (!await cacheFile.exists()) continue;

        final text = await cacheFile.readAsString();
        final result = parseAbpFilterListSync(text);
        final globalStyleN = (result.styleRules[''] ?? const []).length;
        final domainStyleN = result.styleRules.entries
            .where((e) => e.key.isNotEmpty)
            .fold<int>(0, (a, e) => a + e.value.length);
        final globalProcN = (result.proceduralActions[''] ?? const []).length;
        final domainProcN = result.proceduralActions.entries
            .where((e) => e.key.isNotEmpty)
            .fold<int>(0, (a, e) => a + e.value.length);
        LogService.instance.log(
            'ContentBlocker',
            'list "${list.name}" (${text.length}B): '
            'converted=${result.convertedCount} skipped=${result.skippedCount} '
            'global hides=${(result.cosmeticSelectors[''] ?? const []).length} '
            'global :style()=$globalStyleN '
            'domain :style()=$domainStyleN '
            'global procedural=$globalProcN '
            'domain procedural=$domainProcN',
            level: LogLevel.debug);
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
        for (final entry in result.proceduralActions.entries) {
          allProceduralActions
              .putIfAbsent(entry.key, () => [])
              .addAll(entry.value);
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
    _proceduralActions = allProceduralActions;
    _isBlockedCache.clear();
    _engineCosmeticCache.clear();
    // Engine state changes invalidate the Apple ruleset cache too —
    // the JSON depends on the current filter set and the toggle.
    _appleContentBlockersCache = null;
    // Diagnostic: surface per-scope counts so a missing sample list /
    // parser drop is visible without re-running with extra logs.
    final globalSelCount = (_cosmeticSelectors[''] ?? const []).length;
    final globalStyleCount = (_styleRules[''] ?? const []).length;
    final globalTextCount = (_textHideRules[''] ?? const []).length;
    final domainStyleCount =
        _styleRules.entries.where((e) => e.key.isNotEmpty).fold<int>(
              0,
              (acc, e) => acc + e.value.length,
            );
    LogService.instance.log(
        'ContentBlocker',
        'rule store: global hides=$globalSelCount '
        'global :style()=$globalStyleCount '
        'global text=$globalTextCount '
        'domain :style()=$domainStyleCount '
        'distinct domains=${_styleRules.keys.where((k) => k.isNotEmpty).length}',
        level: LogLevel.debug);
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
    final rulesText = buf.toString();
    _aggregatedListsText = rulesText;
    _appleContentBlockersCache = null;
    final rulesHash = sha256.convert(utf8.encode(rulesText)).toString();
    AdblockEngine? engine;
    String loadMode = 'parse';
    final sw = Stopwatch()..start();

    // Warm-path: try the on-disk cache before re-parsing 5MB of text.
    // Cache invalidates when the rule text hash OR the uBO toggle
    // changes (the resource pool is re-applied post-deserialize, but
    // the parsed rule set itself is tied to the source text).
    final cached = await _readEngineCache(rulesHash);
    if (cached != null) {
      engine = AdblockEngine.loadFromSerialized(cached,
          enableUboResources: _useUboResources);
      if (engine != null) {
        loadMode = 'deserialize';
      } else {
        // Corrupted blob OR adblock-rust version mismatch. Wipe so
        // the parse path below can write a fresh one.
        await _clearEngineCache();
      }
    }
    engine ??= AdblockEngine.load(rulesText,
        enableUboResources: _useUboResources);
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
        '($loadMode $listCount list(s), ${rulesText.length} bytes, '
        '${sw.elapsedMilliseconds}ms)',
        level: LogLevel.info);
    // Write the cache on the parse path so the NEXT startup hits it.
    // Don't bother on the deserialize path — it was already a hit.
    if (loadMode == 'parse') {
      // Don't block the Rust engine availability on the cache write —
      // the engine is live; we can persist in the background.
      unawaited(_writeEngineCache(rulesHash, engine));
    }
    if (Platform.isAndroid) {
      // Phase 9: also push the rules text to the native engine so
      // FastSubresourceInterceptor can consult it without a Dart
      // roundtrip per sub-resource. The native side spins up its
      // own engine instance from the same text — separate from the
      // Dart-side instance, but both are pure functions of the
      // rules so they always agree on decisions.
      final result =
          await WebInterceptNative.sendAdblockEngineRules(buf.toString(),
              enableUboResources: _useUboResources);
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

  /// Filesystem location of the binary engine cache. Two files:
  ///   `<dir>/.engine.bin`  — flatbuffer blob from `engine.serialize()`.
  ///   `<dir>/.engine.meta` — `<rulesHash>:<uboEnabled>` sidecar.
  ///
  /// The sidecar invalidates the cache when the user toggles uBO
  /// resources or downloads a different list — the .bin only matches
  /// the rule text it was serialized from.
  Future<File> _engineCacheFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheDir/.engine.bin');
  }

  Future<File> _engineCacheMetaFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheDir/.engine.meta');
  }

  /// Read the cache when the sidecar matches the current state.
  /// Returns null on miss (file absent, hash mismatch, IO error).
  Future<Uint8List?> _readEngineCache(String expectedHash) async {
    try {
      final meta = await _engineCacheMetaFile();
      if (!await meta.exists()) return null;
      final metaText = await meta.readAsString();
      // sidecar format: "<rulesHash>:<uboEnabled 0/1>"
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
/// One row in [ContentBlockerService.recentEngineDecisions] — what the
/// engine answered for one sub-resource check, how long it took, when.
class EngineDecisionSample {
  final String url;
  final String requestType;
  final int micros;
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
  /// Procedural cosmetic actions (`##selector:remove()`,
  /// `##selector:upward(N)`, `##selector:nth-ancestor(N)`, etc.) as raw
  /// JSON strings — uBO's wire format. Each entry parses into a tree
  /// the page-side shim walks at runtime.
  final List<String> proceduralActions;
  _EngineCosmeticCache({
    required this.hides,
    required this.exceptions,
    required this.genericHide,
    required this.proceduralActions,
  });
}
