import 'package:webspace/services/block_stats_engine.dart';

/// One thing the blockers stopped, folded across the running session: a
/// blocked host, the set of tracking parameters stripped from a URL, or the
/// CDN origin a cached copy stood in for.
class BlockDetailItem {
  final String label;
  int count;
  DateTime lastSeen;

  BlockDetailItem({
    required this.label,
    required this.count,
    required this.lastSeen,
  });
}

/// Session-scoped substance behind the report's category rows (STATS-008).
///
/// The persisted engine answers "how much" and deliberately keeps no host and
/// no `siteId` (STATS-005). This holds the "what, and for which site" for the
/// running process only: it lives in memory, is never serialised, and dies
/// with the process, so the report's on-disk shape stays a bare count per
/// category per day.
class BlockStatsDetail {
  /// Per-category cap on distinct items. A long session on a hostile page can
  /// touch thousands of hosts; the UI only ever shows the head of the list,
  /// so the tail is evicted least-frequent-first.
  static const int maxItemsPerCategory = 120;

  final Map<BlockCategory, Map<String, BlockDetailItem>> _items = {};
  final Map<BlockCategory, Map<String, int>> _sites = {};

  bool get isEmpty => _items.isEmpty && _sites.isEmpty;

  /// Fold [count] events of [category] attributed to [siteId] into the
  /// session detail. A null or empty [label] still moves the per-site
  /// counter: a category that cannot name what it stopped is still worth
  /// attributing.
  void record(
    BlockCategory category, {
    required String siteId,
    String? label,
    int count = 1,
    DateTime? now,
  }) {
    if (count < 1) return;
    final at = now ?? DateTime.now();
    if (siteId.isNotEmpty) {
      final sites = _sites.putIfAbsent(category, () => <String, int>{});
      sites[siteId] = (sites[siteId] ?? 0) + count;
    }
    final key = label?.trim().toLowerCase();
    if (key == null || key.isEmpty) return;
    final items =
        _items.putIfAbsent(category, () => <String, BlockDetailItem>{});
    final existing = items[key];
    if (existing != null) {
      existing.count += count;
      existing.lastSeen = at;
      return;
    }
    if (items.length >= maxItemsPerCategory) {
      _evictLeast(items);
    }
    items[key] = BlockDetailItem(label: key, count: count, lastSeen: at);
  }

  /// Items of [category], most frequent first, ties broken by recency.
  List<BlockDetailItem> topItems(BlockCategory category, {int limit = 25}) {
    final items = _items[category];
    if (items == null || items.isEmpty) return const <BlockDetailItem>[];
    final out = items.values.toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : b.lastSeen.compareTo(a.lastSeen);
      });
    return out.length <= limit ? out : out.sublist(0, limit);
  }

  /// `siteId` -> count for [category], most blocked first.
  List<MapEntry<String, int>> siteCounts(BlockCategory category) {
    final sites = _sites[category];
    if (sites == null || sites.isEmpty) return const <MapEntry<String, int>>[];
    return sites.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  /// Events of [category] seen this session, across every item and site.
  int sessionTotal(BlockCategory category) =>
      (_sites[category]?.values ?? const <int>[])
          .fold<int>(0, (a, b) => a + b);

  void clear() {
    _items.clear();
    _sites.clear();
  }

  static void _evictLeast(Map<String, BlockDetailItem> items) {
    String? victim;
    BlockDetailItem? worst;
    for (final entry in items.entries) {
      final item = entry.value;
      if (worst == null ||
          item.count < worst.count ||
          (item.count == worst.count && item.lastSeen.isBefore(worst.lastSeen))) {
        worst = item;
        victim = entry.key;
      }
    }
    if (victim != null) items.remove(victim);
  }
}
