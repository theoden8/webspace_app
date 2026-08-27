import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/block_stats_detail.dart';
import 'package:webspace/services/block_stats_detail_storage.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/log_service.dart';

/// Persistent, app-wide block statistics behind the protection report
/// (STATS-001).
///
/// Per-site live counters stay in `DnsBlockService` (session-scoped, keyed by
/// siteId). This service is the aggregate, kept in two stores with different
/// contents: per-category daily totals in plaintext SharedPreferences, and
/// the itemised detail (blocked hosts, per-site counts) in an encrypted blob
/// (STATS-009), so the plaintext half still cannot be mined for which sites
/// the user visits.
///
/// **Archive neutrality (ARCH-006).** A site only contributes once
/// [setSiteContributes] has declared it app-tier. Unknown siteIds are
/// ignored, so an archive-tier site whose scope was never declared can never
/// move a counter that lands in plaintext SharedPreferences.
class BlockStatsService {
  static const String prefsKey = 'blockStatsV1';

  /// How long a burst must go quiet before it is persisted. Block events
  /// arrive in bursts of hundreds per page load; the timer restarts on each
  /// one, so the burst costs a single write and lands shortly after the page
  /// settles rather than at the far end of a fixed window.
  static const Duration flushDelay = Duration(seconds: 2);

  /// Ceiling on how long a recorded count may sit unpersisted, measured from
  /// the first unflushed record. A page that keeps firing blocked requests
  /// (an infinite feed, a long-poll) would otherwise hold the idle debounce
  /// open for as long as the user keeps browsing.
  static const Duration maxFlushDelay = Duration(seconds: 10);

  static BlockStatsService? _instance;
  static BlockStatsService get instance => _instance ??= BlockStatsService._();

  BlockStatsService._();

  /// Test seam: drop the singleton so each test starts from a clean engine.
  @visibleForTesting
  static void resetInstanceForTest() {
    _instance?._cancelFlushTimers();
    _instance = null;
  }

  BlockStatsEngine _engine = BlockStatsEngine();
  final BlockStatsDetail _detail = BlockStatsDetail();
  BlockStatsDetailStore? _detailStore;
  final Set<String> _contributingSiteIds = <String>{};
  final Set<VoidCallback> _listeners = <VoidCallback>{};
  Timer? _idleFlushTimer;
  Timer? _maxFlushTimer;
  Future<void> _flushChain = Future<void>.value();
  Future<void>? _initFuture;
  bool _notifyScheduled = false;
  bool _initialized = false;

  BlockStatsEngine get engine => _engine;

  /// Per-item / per-site detail (STATS-008). Persisted, but only through
  /// [BlockStatsDetailStore]: the plaintext report stays a bare count per
  /// category per day.
  BlockStatsDetail get detail => _detail;

  bool get isInitialized => _initialized;

  /// Load the persisted counters and the encrypted detail. Safe to call more
  /// than once: concurrent callers await the same load, and later calls are
  /// no-ops, so a re-entrant startup path cannot replace an engine that has
  /// already taken counts.
  Future<void> initialize({
    @visibleForTesting BlockStatsDetailStore? detailStore,
  }) {
    return _initFuture ??= _initialize(detailStore);
  }

  Future<void> _initialize(BlockStatsDetailStore? detailStore) async {
    _initialized = true;
    _detailStore = detailStore ?? SecureBlockStatsDetailStore();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _engine = BlockStatsEngine.fromJson(decoded);
        }
      }
    } catch (e) {
      LogService.instance.log('BlockStats', 'Failed to load stats: $e',
          level: LogLevel.warning);
      _engine = BlockStatsEngine();
    }
    await _loadDetail();
    // Both, then decide: `||` would short-circuit the detail out of every
    // launch that pruned a counter bucket.
    final pruned = _engine.prune() + _detail.prune();
    if (pruned > 0) {
      unawaited(flush());
    }
    notifyListeners();
  }

  Future<void> _loadDetail() async {
    try {
      final raw = await _detailStore?.read();
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _detail.mergeFromJson(decoded);
      }
    } catch (e) {
      LogService.instance.log('BlockStats', 'Failed to load detail: $e',
          level: LogLevel.warning);
    }
  }

  /// Drop per-site detail rows for sites that no longer exist. Called from
  /// the orphan sweep alongside every other per-`siteId` store.
  Future<void> removeOrphanedSites(Set<String> liveSiteIds) async {
    if (_detail.retainSites(liveSiteIds) == 0) return;
    await flush();
  }

  /// Declare whether [siteId]'s block events roll into the app-wide report.
  /// Called from the webview factory for every webview built, so the answer
  /// always arrives before the first block event for that site.
  void setSiteContributes(String siteId, bool contributes) {
    if (siteId.isEmpty) return;
    if (contributes) {
      _contributingSiteIds.add(siteId);
    } else {
      _contributingSiteIds.remove(siteId);
    }
  }

  @visibleForTesting
  bool siteContributes(String siteId) => _contributingSiteIds.contains(siteId);

  /// Record [count] block events of [category] attributed to [siteId].
  /// Ignored for sites that have not been declared app-tier. [label] names
  /// what was stopped (a host, the stripped parameters) and only ever reaches
  /// the in-memory [detail].
  void record(String siteId, BlockCategory category,
      {int count = 1, String? label}) {
    if (count < 1) return;
    if (!_contributingSiteIds.contains(siteId)) return;
    _engine.record(category, count: count);
    _detail.record(category, siteId: siteId, label: label, count: count);
    _scheduleFlush();
    _scheduleNotify();
  }

  Future<void> reset() async {
    _engine.reset();
    _detail.clear();
    _detail.markClean();
    await flush();
    // Delete rather than write an empty blob: nothing is then left for the
    // next launch to merge back in.
    await _detailStore?.clear();
    notifyListeners();
  }

  /// Persist now. Called on the debounce timer, on every step away from the
  /// foreground, and after a reset.
  Future<void> flush() {
    _cancelFlushTimers();
    // Serialised rather than concurrent: two flushes encoding the same
    // counters can land the older payload last, which drops the difference
    // until something else marks the engine dirty again.
    final next =
        _flushChain.then((_) => _flushCounters()).then((_) => _flushDetail());
    _flushChain = next.catchError((_) {});
    return next;
  }

  Future<void> _flushCounters() async {
    final engine = _engine;
    if (!engine.isDirty) return;
    final revision = engine.revision;
    final payload = jsonEncode(engine.toJson());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, payload);
      // Clean only what this payload carried. Marking clean before the write
      // hands the counters to a write that may never land, and anything
      // recorded while it was in flight is not in the payload at all.
      engine.markCleanAt(revision);
    } catch (e) {
      LogService.instance.log('BlockStats', 'Failed to persist stats: $e',
          level: LogLevel.warning);
    }
  }

  Future<void> _flushDetail() async {
    final store = _detailStore;
    if (store == null || !_detail.isDirty) return;
    final revision = _detail.revision;
    final payload = jsonEncode(_detail.toJson());
    if (await store.write(payload)) _detail.markCleanAt(revision);
  }

  void _scheduleFlush() {
    _idleFlushTimer?.cancel();
    _idleFlushTimer = Timer(flushDelay, () => unawaited(flush()));
    // Armed once per pending batch and never restarted: the idle timer above
    // restarts on every event, so a page that keeps blocking requests would
    // otherwise hold the batch in memory for as long as it browses.
    _maxFlushTimer ??= Timer(maxFlushDelay, () => unawaited(flush()));
  }

  void _cancelFlushTimers() {
    _idleFlushTimer?.cancel();
    _idleFlushTimer = null;
    _maxFlushTimer?.cancel();
    _maxFlushTimer = null;
  }

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void notifyListeners() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }

  /// Coalesce listener notifications across a microtask: a page load records
  /// hundreds of blocks in well under a frame, and the report only needs one
  /// rebuild for the batch.
  void _scheduleNotify() {
    if (_listeners.isEmpty || _notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}
