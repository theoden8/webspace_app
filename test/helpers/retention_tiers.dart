import 'package:webspace/services/site_retention_priority.dart';

/// The tiers `SiteRuntime.retentionPriority` yields for the sites it protects
/// ([active]: on screen or activating) and the selected webspace's ([keep]).
SiteRetentionResolver tiers({
  Set<int> active = const {},
  Set<int> keep = const {},
}) =>
    (i) => active.contains(i)
        ? SiteRetentionPriority.active
        : keep.contains(i)
            ? SiteRetentionPriority.webspace
            : SiteRetentionPriority.loaded;
