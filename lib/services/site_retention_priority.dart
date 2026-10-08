/// Named retention priorities for loaded sites, ordered from highest
/// (never evict) to lowest (evict first). Every eviction picks through
/// [evictionOrder].
///
/// Adding a new priority level: insert it at the right position in the
/// enum (Dart enums compare by index), say whether it is [evictable], then
/// update the call site in `_WebSpacePageState` that computes each site's
/// priority.
enum SiteRetentionPriority {
  /// Currently focused site — never evicted.
  active,

  /// Target of an in-flight `_setCurrentIndex` — never evicted.
  activating,

  /// User explicitly opted this site into notifications (which implies
  /// background polling) — evicting it silently breaks the user's intent.
  notification,

  /// In the active webspace — evict only after lower-priority sites.
  webspace,

  /// Loaded but not in the active webspace and no special status.
  loaded;

  bool get evictable => switch (this) {
        active || activating => false,
        notification || webspace || loaded => true,
      };
}

/// Resolves a site's retention priority. Higher priority (lower enum
/// index) means "harder to evict". The [targetIndex] (the site about
/// to be activated) is implicitly protected at the call site and should
/// not be passed through this function.
typedef SiteRetentionResolver = SiteRetentionPriority Function(int index);

/// [candidates] in the order eviction takes them: lowest retention priority
/// first and, within a priority, in the order given, which callers keep
/// least recently used first. Sites that are not [SiteRetentionPriority.evictable]
/// are left out.
///
/// Bucketed rather than sorted: `List.sort` is not stable, and the order
/// within a priority is the LRU order.
List<int> evictionOrder(
  Iterable<int> candidates,
  SiteRetentionResolver priorityOf,
) {
  final buckets = [for (final _ in SiteRetentionPriority.values) <int>[]];
  for (final i in candidates) {
    buckets[priorityOf(i).index].add(i);
  }
  return [
    for (final p in SiteRetentionPriority.values.reversed)
      if (p.evictable) ...buckets[p.index],
  ];
}
