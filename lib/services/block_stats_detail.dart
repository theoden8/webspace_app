import 'package:webspace/services/block_stats_engine.dart';

/// One thing the blockers stopped, folded across the retention window: a
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

  /// Positional rather than keyed: several hundred of these share one blob
  /// and the key names would outweigh the data.
  List<Object> toJson() => [label, count, lastSeen.millisecondsSinceEpoch];

  static BlockDetailItem? fromJson(Object? raw) {
    if (raw is! List || raw.length != 3) return null;
    final label = raw[0];
    final count = raw[1];
    final lastSeen = raw[2];
    if (label is! String || label.isEmpty) return null;
    if (count is! int || count < 1) return null;
    if (lastSeen is! int) return null;
    return BlockDetailItem(
      label: label,
      count: count,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(lastSeen),
    );
  }
}

/// The substance behind the report's category rows (STATS-008): what was
/// actually stopped, and which site it was stopped for.
///
/// Kept across restarts (STATS-009) but never in the plaintext blob: hosts
/// and `siteId`s are browsing-derived, so [BlockStatsService] hands this to
/// an encrypted store while the SharedPreferences counters stay a bare count
/// per category per day (STATS-005).
class BlockStatsDetail {
  static const int schemaVersion = 1;

  /// Per-category cap on distinct items. A long session on a hostile page can
  /// touch thousands of hosts; the UI only ever shows the head of the list,
  /// so the tail is evicted least-frequent-first.
  static const int maxItemsPerCategory = 120;

  /// Same cap for per-site rows. Sites deleted since a row was written keep
  /// it until retention drops it, so this is not bounded by the site count.
  static const int maxSitesPerCategory = 120;

  final Map<BlockCategory, Map<String, BlockDetailItem>> _items = {};
  final Map<BlockCategory, Map<String, BlockDetailItem>> _sites = {};
  bool _dirty = false;
  int _revision = 0;

  bool get isEmpty => _items.isEmpty && _sites.isEmpty;

  /// True when a mutation has not been persisted yet.
  bool get isDirty => _dirty;

  /// Bumped by every mutation. Read it before encoding a payload and hand it
  /// back to [markCleanAt] once that payload is on disk.
  int get revision => _revision;

  void markClean() => _dirty = false;

  /// Clear the dirty flag only if nothing has been recorded since [revision]
  /// was read, so rows folded in while a write was in flight stay pending.
  void markCleanAt(int revision) {
    if (revision == _revision) _dirty = false;
  }

  /// Fold [count] events of [category] attributed to [siteId] into the
  /// detail. A null or empty [label] still moves the per-site counter: a
  /// category that cannot name what it stopped is still worth attributing.
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
      _fold(_sites.putIfAbsent(category, () => <String, BlockDetailItem>{}),
          siteId, count, at, maxSitesPerCategory);
      _markDirty();
    }
    final key = label?.trim().toLowerCase();
    if (key == null || key.isEmpty) return;
    _fold(_items.putIfAbsent(category, () => <String, BlockDetailItem>{}), key,
        count, at, maxItemsPerCategory);
    _markDirty();
  }

  /// Items of [category], most frequent first, ties broken by recency.
  List<BlockDetailItem> topItems(BlockCategory category, {int limit = 25}) {
    final items = _items[category];
    if (items == null || items.isEmpty) return const <BlockDetailItem>[];
    final out = items.values.toList()..sort(_byCountThenRecency);
    return out.length <= limit ? out : out.sublist(0, limit);
  }

  /// `siteId` -> count for [category], most blocked first.
  List<MapEntry<String, int>> siteCounts(BlockCategory category) {
    final sites = _sites[category];
    if (sites == null || sites.isEmpty) return const <MapEntry<String, int>>[];
    final out = sites.values.toList()..sort(_byCountThenRecency);
    return [for (final site in out) MapEntry(site.label, site.count)];
  }

  /// Events of [category] held here, across every site.
  int totalFor(BlockCategory category) =>
      (_sites[category]?.values ?? const <BlockDetailItem>[])
          .fold<int>(0, (a, b) => a + b.count);

  /// Drop rows last seen before the retention cutoff, matching the counter
  /// buckets' window. Returns the number dropped.
  int prune({DateTime? now, int retentionDays = BlockStatsEngine.retentionDays}) {
    final at = now ?? DateTime.now();
    final cutoff = DateTime(at.year, at.month, at.day - retentionDays);
    final dropped =
        _pruneTables(_items, cutoff) + _pruneTables(_sites, cutoff);
    if (dropped > 0) _markDirty();
    return dropped;
  }

  /// Drop per-site rows for sites that no longer exist. Item labels are hosts
  /// rather than sites, so they are untouched — the same split the orphan
  /// sweep makes everywhere else.
  int retainSites(Set<String> liveSiteIds) {
    var dropped = 0;
    for (final table in _sites.values) {
      final stale =
          table.keys.where((id) => !liveSiteIds.contains(id)).toList();
      for (final id in stale) {
        table.remove(id);
      }
      dropped += stale.length;
    }
    _sites.removeWhere((_, table) => table.isEmpty);
    if (dropped > 0) _markDirty();
    return dropped;
  }

  void clear() {
    _items.clear();
    _sites.clear();
    _markDirty();
  }

  void _markDirty() {
    _dirty = true;
    _revision++;
  }

  Map<String, dynamic> toJson() => {
        'v': schemaVersion,
        'cats': {
          for (final category in BlockCategory.values)
            if (_items[category]?.isNotEmpty == true ||
                _sites[category]?.isNotEmpty == true)
              blockCategoryKey(category): {
                if (_items[category]?.isNotEmpty == true)
                  'items': [
                    for (final item in _items[category]!.values) item.toJson(),
                  ],
                if (_sites[category]?.isNotEmpty == true)
                  'sites': [
                    for (final site in _sites[category]!.values) site.toJson(),
                  ],
              },
        },
      };

  /// Fold a stored blob into whatever is already in memory, so a block
  /// recorded before the load lands rather than being overwritten. Tolerant
  /// of unknown categories and malformed rows: a corrupt blob degrades to
  /// fewer rows, never a startup crash. Loading is not a mutation, so it does
  /// not by itself mark the detail dirty.
  void mergeFromJson(Map<String, dynamic> json) {
    final cats = json['cats'];
    if (cats is! Map) return;
    for (final entry in cats.entries) {
      final category = blockCategoryFromKey(entry.key.toString());
      final value = entry.value;
      if (category == null || value is! Map) continue;
      _mergeTable(
          _items.putIfAbsent(category, () => <String, BlockDetailItem>{}),
          value['items'],
          maxItemsPerCategory);
      _mergeTable(
          _sites.putIfAbsent(category, () => <String, BlockDetailItem>{}),
          value['sites'],
          maxSitesPerCategory);
    }
    _items.removeWhere((_, table) => table.isEmpty);
    _sites.removeWhere((_, table) => table.isEmpty);
  }

  static int _byCountThenRecency(BlockDetailItem a, BlockDetailItem b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : b.lastSeen.compareTo(a.lastSeen);
  }

  static void _fold(Map<String, BlockDetailItem> table, String key, int count,
      DateTime at, int cap) {
    final existing = table[key];
    if (existing != null) {
      existing.count += count;
      existing.lastSeen = at;
      return;
    }
    if (table.length >= cap) _evictLeast(table);
    table[key] = BlockDetailItem(label: key, count: count, lastSeen: at);
  }

  static void _mergeTable(
      Map<String, BlockDetailItem> table, Object? raw, int cap) {
    if (raw is! List) return;
    for (final row in raw) {
      final stored = BlockDetailItem.fromJson(row);
      if (stored == null) continue;
      final existing = table[stored.label];
      if (existing == null) {
        table[stored.label] = stored;
        continue;
      }
      existing.count += stored.count;
      if (stored.lastSeen.isAfter(existing.lastSeen)) {
        existing.lastSeen = stored.lastSeen;
      }
    }
    while (table.length > cap) {
      _evictLeast(table);
    }
  }

  static int _pruneTables(
      Map<BlockCategory, Map<String, BlockDetailItem>> tables, DateTime cutoff) {
    var dropped = 0;
    for (final table in tables.values) {
      final stale = table.entries
          .where((e) => e.value.lastSeen.isBefore(cutoff))
          .map((e) => e.key)
          .toList();
      for (final key in stale) {
        table.remove(key);
      }
      dropped += stale.length;
    }
    tables.removeWhere((_, table) => table.isEmpty);
    return dropped;
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
