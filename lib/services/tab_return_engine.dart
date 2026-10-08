/// The way back through jumps the Tabs sheet makes between sites' slots.
///
/// Spec: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md`
/// (TAB-019). A tab in another site's tree opens in that site's slot, so the
/// sheet records where the screen was; Back at the start of the tab it opened
/// goes there instead of closing it (TAB-007). The trail holds only while the
/// screen stays where the last jump put it.
library;

/// One jump from [fromTabId] in [fromSiteId]'s slot to [toTabId] in
/// [toSiteId]'s.
class TabReturn {
  const TabReturn({
    required this.fromSiteId,
    required this.fromTabId,
    required this.toSiteId,
    required this.toTabId,
    this.webspaceId,
  });

  final String fromSiteId;
  final String fromTabId;
  final String toSiteId;
  final String toTabId;

  /// The webspace selected before the jump, which may have switched to All
  /// to show the site it went to (WEBSPACE-012).
  final String? webspaceId;

  bool leadsBackTo(String siteId, {required String tabId}) =>
      fromSiteId == siteId && fromTabId == tabId;
}

abstract final class TabReturnEngine {
  /// Jumps kept; past this, the oldest go.
  static const int limit = 20;

  /// The jump Back undoes while [activeTabId] of [siteId] is on screen, or
  /// null when that is not where the last jump landed.
  static TabReturn? wayBack(
    List<TabReturn> trail, {
    required String siteId,
    required String activeTabId,
  }) {
    if (trail.isEmpty) return null;
    final last = trail.last;
    return last.toSiteId == siteId && last.toTabId == activeTabId ? last : null;
  }

  /// The trail once the sheet has opened [toTabId] of [toSiteId] while
  /// [fromTabId] of [fromSiteId] was on screen: going back where the last
  /// jump came from takes it off, a jump to another site's slot adds one,
  /// and another tab of the same site leaves the trail behind.
  static List<TabReturn> afterOpen(
    List<TabReturn> trail, {
    required String fromSiteId,
    required String fromTabId,
    required String toSiteId,
    required String toTabId,
    String? webspaceId,
  }) {
    final back = wayBack(trail, siteId: fromSiteId, activeTabId: fromTabId);
    if (back != null && back.leadsBackTo(toSiteId, tabId: toTabId)) {
      return trail.sublist(0, trail.length - 1);
    }
    if (fromSiteId == toSiteId) return const [];
    // A trail the screen has left some other way no longer leads anywhere.
    final kept = back == null ? const <TabReturn>[] : trail;
    final next = [
      ...kept,
      TabReturn(
        fromSiteId: fromSiteId,
        fromTabId: fromTabId,
        toSiteId: toSiteId,
        toTabId: toTabId,
        webspaceId: webspaceId,
      ),
    ];
    return next.length > limit ? next.sublist(next.length - limit) : next;
  }
}
