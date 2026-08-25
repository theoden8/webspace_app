/// Pure aggregation engine behind the protection report (STATS-001).
///
/// Holds daily buckets of block events per category, an all-time total, and
/// the timestamp counting started from. No Flutter, no I/O: the owning
/// [BlockStatsService] handles persistence and gating.
library;

/// What blocked a request. Each value maps to a mechanism the app already
/// runs, so a count is never inferred from a category the app cannot
/// attribute.
enum BlockCategory {
  /// ABP filter list match (EasyList, EasyPrivacy, Fanboy's, custom).
  filterList,

  /// Hagezi DNS blocklist match.
  dnsBlocklist,

  /// ClearURLs stripped at least one tracking parameter from a URL.
  trackingParam,

  /// A third-party CDN request was served from the local LocalCDN cache
  /// instead of reaching the CDN.
  localCdn,
}

const Map<BlockCategory, String> _categoryKeys = {
  BlockCategory.filterList: 'abp',
  BlockCategory.dnsBlocklist: 'dns',
  BlockCategory.trackingParam: 'param',
  BlockCategory.localCdn: 'cdn',
};

BlockCategory? _categoryFromKey(String key) {
  for (final entry in _categoryKeys.entries) {
    if (entry.value == key) return entry.key;
  }
  return null;
}

class BlockStatsEngine {
  /// Daily buckets older than this are dropped on the next [prune]. The
  /// all-time totals are kept independently, so pruning never rewrites
  /// the headline number.
  static const int retentionDays = 90;

  static const int schemaVersion = 1;

  /// Buckets keyed by local calendar day as `yyyymmdd`. The encoding is
  /// chronologically ordered as an int, so pruning is a less-than comparison.
  final Map<int, Map<BlockCategory, int>> _days;
  final Map<BlockCategory, int> _allTime;

  DateTime _since;
  bool _dirty = false;

  BlockStatsEngine({
    DateTime? since,
    Map<int, Map<BlockCategory, int>>? days,
    Map<BlockCategory, int>? allTime,
  })  : _since = since ?? DateTime.now(),
        _days = days ?? <int, Map<BlockCategory, int>>{},
        _allTime = allTime ?? <BlockCategory, int>{};

  /// When counting started. Rendered as the report's "N blocked since" date.
  DateTime get since => _since;

  /// True when a mutation has not been persisted yet.
  bool get isDirty => _dirty;

  void markClean() => _dirty = false;

  static int dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  void record(BlockCategory category, {int count = 1, DateTime? now}) {
    if (count < 1) return;
    final at = now ?? DateTime.now();
    final bucket = _days.putIfAbsent(dayKey(at), () => <BlockCategory, int>{});
    bucket[category] = (bucket[category] ?? 0) + count;
    _allTime[category] = (_allTime[category] ?? 0) + count;
    _dirty = true;
  }

  /// Per-category totals over the [days] calendar days ending today
  /// (inclusive), so `days: 7` is "this week" in the user's own timezone.
  Map<BlockCategory, int> totalsForLastDays(int days, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final out = <BlockCategory, int>{};
    for (var i = 0; i < days; i++) {
      final key = dayKey(DateTime(at.year, at.month, at.day - i));
      final bucket = _days[key];
      if (bucket == null) continue;
      for (final entry in bucket.entries) {
        out[entry.key] = (out[entry.key] ?? 0) + entry.value;
      }
    }
    return out;
  }

  int totalForLastDays(int days, {DateTime? now}) =>
      totalsForLastDays(days, now: now).values.fold(0, (a, b) => a + b);

  /// Daily totals oldest-first over the [days] window, for the bar chart.
  /// With [category] given, only that category's events count, so a category
  /// drill-down charts the same window on the same scale.
  List<int> dailyTotals(int days, {DateTime? now, BlockCategory? category}) {
    final at = now ?? DateTime.now();
    return List<int>.generate(days, (i) {
      final key = dayKey(DateTime(at.year, at.month, at.day - (days - 1 - i)));
      final bucket = _days[key];
      if (bucket == null) return 0;
      if (category != null) return bucket[category] ?? 0;
      return bucket.values.fold(0, (a, b) => a + b);
    });
  }

  Map<BlockCategory, int> get allTimeTotals =>
      Map<BlockCategory, int>.unmodifiable(_allTime);

  int get allTimeTotal => _allTime.values.fold(0, (a, b) => a + b);

  int allTimeFor(BlockCategory category) => _allTime[category] ?? 0;

  /// Drop buckets older than [retentionDays]. Returns the number dropped.
  int prune({DateTime? now}) {
    final at = now ?? DateTime.now();
    final cutoff = dayKey(DateTime(at.year, at.month, at.day - retentionDays));
    final stale = _days.keys.where((k) => k < cutoff).toList();
    for (final k in stale) {
      _days.remove(k);
    }
    if (stale.isNotEmpty) _dirty = true;
    return stale.length;
  }

  /// Wipe every counter and restart the "since" clock.
  void reset({DateTime? now}) {
    _days.clear();
    _allTime.clear();
    _since = now ?? DateTime.now();
    _dirty = true;
  }

  Map<String, dynamic> toJson() => {
        'v': schemaVersion,
        'since': _since.toIso8601String(),
        'allTime': {
          for (final entry in _allTime.entries)
            _categoryKeys[entry.key]!: entry.value,
        },
        'days': {
          for (final day in _days.entries)
            day.key.toString(): {
              for (final entry in day.value.entries)
                _categoryKeys[entry.key]!: entry.value,
            },
        },
      };

  /// Tolerant of unknown categories and malformed buckets: a corrupt
  /// stats blob degrades to a smaller count, never a startup crash.
  factory BlockStatsEngine.fromJson(Map<String, dynamic> json) {
    final days = <int, Map<BlockCategory, int>>{};
    final rawDays = json['days'];
    if (rawDays is Map) {
      for (final entry in rawDays.entries) {
        final key = int.tryParse(entry.key.toString());
        final value = entry.value;
        if (key == null || value is! Map) continue;
        final bucket = _countsFromJson(value);
        if (bucket.isNotEmpty) days[key] = bucket;
      }
    }
    final rawAll = json['allTime'];
    return BlockStatsEngine(
      since: DateTime.tryParse(json['since']?.toString() ?? '') ?? DateTime.now(),
      days: days,
      allTime: rawAll is Map ? _countsFromJson(rawAll) : null,
    );
  }

  static Map<BlockCategory, int> _countsFromJson(Map<dynamic, dynamic> raw) {
    final out = <BlockCategory, int>{};
    for (final entry in raw.entries) {
      final category = _categoryFromKey(entry.key.toString());
      final count = entry.value;
      if (category == null || count is! int || count <= 0) continue;
      out[category] = count;
    }
    return out;
  }
}
