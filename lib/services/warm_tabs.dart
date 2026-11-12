import 'package:webspace/services/site_tab.dart';

/// How many warm tabs a site's slot keeps (TAB-023): [own] while it runs as
/// itself, and up to [hosted] more while its warm tabs run as another site.
typedef WarmLimits = ({int own, int hosted});

/// The limits the app runs with.
const WarmLimits kWarmLimits = (own: 3, hosted: 2);

/// Which of [among], the warm tabs the limit lets one go from, goes: the
/// one used longest ago, [inUse] (the tab shown until now) last (TAB-023).
/// The model may take any of them.
TabId? leastRecentlyUsed(
  List<TabId?> among, {
  required List<SiteTab> tabs,
  required TabId? inUse,
}) {
  final used = {for (final t in tabs) t.id: t.lastActiveAt};
  bool before(TabId a, {required TabId than}) =>
      than == inUse || (a != inUse && used[a]!.isBefore(used[than]!));
  TabId? oldest;
  for (final id in among) {
    if (id == null) return null;
    if (oldest == null || before(id, than: oldest)) oldest = id;
  }
  return oldest;
}
