import 'dart:typed_data';

import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/site_ids.dart';

/// One tab a close took (TAB-022): the tab as it was listed, where it stood,
/// the tabs the close moved up from under it, and the back stack its file
/// held, which a reopen writes back.
final class ClosedTab {
  ClosedTab({required this.tab, required this.index, required this.adopt});

  /// The tab as it was listed: its id, address, title, parent and the site
  /// it ran as.
  final SiteTab tab;

  /// Its place in its site's list as the close began.
  final int index;

  /// Its children, which a close of the tab alone moved up to its parent
  /// (TAB-007): a reopen puts back under it those still hanging there.
  final Set<TabId> adopt;

  /// Its back stack, taken from its file as the close removed it.
  Uint8List? history;
}

/// What one close took from one site, in tree order: the tab asked for
/// first, then its subtree when the close took that too.
final class ClosedTabs {
  ClosedTabs({required this.site, required this.tabs})
      : assert(tabs.isNotEmpty, 'a close takes at least the tab asked for');

  final SiteId site;
  final List<ClosedTab> tabs;

  /// The tab the close was asked for.
  SiteTab get first => tabs.first.tab;
}

/// The closes of this run a reopen may take back, newest first, at most
/// [cap] of them. Held in memory only: nothing of a closed tab outlives the
/// run (INC-002), and a site that leaves the list takes its closes with it.
final class RecentlyClosed {
  RecentlyClosed({this.cap = 10}) : assert(cap > 0, 'a cap keeps one at least');

  final int cap;
  final List<ClosedTabs> _closes = [];

  List<ClosedTabs> get closes => List.unmodifiable(_closes);

  void push(ClosedTabs closed) {
    _closes.insert(0, closed);
    if (_closes.length > cap) _closes.removeRange(cap, _closes.length);
  }

  /// The newest close of [site], or null when it has none.
  ClosedTabs? latestOf(SiteId site) =>
      _closes.where((c) => c.site == site).firstOrNull;

  /// [closed] out of the list, as a reopen takes it. False when it is no
  /// longer there.
  bool take(ClosedTabs closed) => _closes.remove(closed);

  /// Only the closes of [listed] sites stay.
  void keepOnly(Set<SiteId> listed) =>
      _closes.removeWhere((c) => !listed.contains(c.site));
}
