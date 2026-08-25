import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/block_stats_detail.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/log_service.dart';

/// Persistent, app-wide block statistics behind the protection report
/// (STATS-001).
///
/// Per-site live counters stay in `DnsBlockService` (session-scoped, keyed by
/// siteId). This service is the aggregate: no siteId is ever persisted, only
/// per-category daily totals, so the report cannot be mined for which sites
/// the user visits.
///
/// **Archive neutrality (ARCH-006).** A site only contributes once
/// [setSiteContributes] has declared it app-tier. Unknown siteIds are
/// ignored, so an archive-tier site whose scope was never declared can never
/// move a counter that lands in plaintext SharedPreferences.
class BlockStatsService {
  static const String prefsKey = 'blockStatsV1';

  /// How long a mutation may sit unpersisted. Block events arrive in bursts
  /// of hundreds per page load; coalescing keeps that to one write.
  static const Duration flushDelay = Duration(seconds: 10);

  static BlockStatsService? _instance;
  static BlockStatsService get instance => _instance ??= BlockStatsService._();

  BlockStatsService._();

  /// Test seam: drop the singleton so each test starts from a clean engine.
  @visibleForTesting
  static void resetInstanceForTest() => _instance = null;

  BlockStatsEngine _engine = BlockStatsEngine();
  final BlockStatsDetail _detail = BlockStatsDetail();
  final Set<String> _contributingSiteIds = <String>{};
  final Set<VoidCallback> _listeners = <VoidCallback>{};
  Timer? _flushTimer;
  Future<void>? _initFuture;
  bool _notifyScheduled = false;
  bool _initialized = false;

  BlockStatsEngine get engine => _engine;

  /// Session-scoped per-item / per-site detail (STATS-008). Never persisted:
  /// the report on disk stays a bare count per category per day.
  BlockStatsDetail get detail => _detail;

  bool get isInitialized => _initialized;

  /// Load persisted counters. Safe to call more than once: concurrent callers
  /// await the same load, and later calls are no-ops, so a re-entrant startup
  /// path cannot replace an engine that has already taken counts.
  Future<void> initialize() {
    return _initFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    _initialized = true;
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
    if (_engine.prune() > 0) {
      unawaited(flush());
    }
    notifyListeners();
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
    await flush();
    notifyListeners();
  }

  /// Persist now. Called on the debounce timer, on app pause, and after a
  /// reset.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_engine.isDirty) return;
    final payload = jsonEncode(_engine.toJson());
    _engine.markClean();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, payload);
    } catch (e) {
      LogService.instance.log('BlockStats', 'Failed to persist stats: $e',
          level: LogLevel.warning);
    }
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(flushDelay, () {
      _flushTimer = null;
      unawaited(flush());
    });
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
