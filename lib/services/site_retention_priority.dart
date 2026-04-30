/// Named retention priorities for loaded sites, ordered from highest
/// (never evict) to lowest (evict first). The unload and lifecycle-
/// promotion engines sort candidates by priority and evict lowest first.
///
/// Adding a new priority level: insert it at the right position in the
/// enum (Dart enums compare by index), then update the call site in
/// `_WebSpacePageState` that computes each site's priority.
enum SiteRetentionPriority {
  /// Currently focused site — never evicted.
  active,

  /// Target of an in-flight `_setCurrentIndex` — never evicted.
  activating,

  /// User explicitly opted this site into notifications or background
  /// polling — evicting it silently breaks the user's intent.
  notification,

  /// In the active webspace — evict only after lower-priority sites.
  webspace,

  /// Loaded but not in the active webspace and no special status.
  loaded,
}

/// Resolves a site's retention priority. Higher priority (lower enum
/// index) means "harder to evict". The [targetIndex] (the site about
/// to be activated) is implicitly protected at the call site and should
/// not be passed through this function.
typedef SiteRetentionResolver = SiteRetentionPriority Function(int index);
