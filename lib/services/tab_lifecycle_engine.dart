/// Pure-Dart logic engine for a site's tab list.
///
/// Spec: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md`
/// (TAB-001..TAB-008). Mirrors the engine pattern in `cookie_isolation.dart` /
/// `site_lifecycle_engine.dart`: the engine owns the graph arithmetic — tree
/// order, re-parenting on close, which tab takes over, what the back gesture
/// means — and returns a plan. `_WebSpacePageState` performs the IO
/// (`captureNavigationState`, `disposeWebView`, `schedulePendingRestoreState`,
/// `setState`, persistence). No Flutter, no platform channels, no setState.
library;

import 'package:webspace/services/site_tab.dart';

/// One row of the tab tree: the tab and how deep it sits under its root.
class TabRow {
  const TabRow(this.tab, this.depth, {this.childCount = 0});

  final SiteTab tab;
  final int depth;
  final int childCount;

  @override
  String toString() => 'TabRow(${tab.id}, depth=$depth, children=$childCount)';
}

/// Result of a close. [tabs] is the surviving list in its original order;
/// [nextActiveId] names the tab that should take the webview, or is null and
/// the caller must seed a fresh home tab.
class TabCloseResult {
  TabCloseResult({
    required this.tabs,
    required this.nextActiveId,
    required this.closedIds,
    required this.activeChanged,
  }) : assert((nextActiveId == null) == tabs.isEmpty,
            'a close names the next tab exactly when one survives');

  final List<SiteTab> tabs;
  final String? nextActiveId;

  /// Every tab removed, so the caller can drop each one's saved state bytes.
  final List<String> closedIds;

  /// Whether the webview has to be re-bound. False when the closed tabs were
  /// all parked: nothing on screen changed, so no capture/dispose/restore.
  final bool activeChanged;
}

/// Where a dragged tab lands against the row it is dropped on (TAB-015).
enum TabDropZone {
  /// The row's sibling, just before it.
  before,

  /// The row's last child.
  into,

  /// Just below the row: its first child when its children are showing,
  /// else its sibling after its whole subtree.
  after,
}

/// A drop in the tab list: on a row, or past the last row.
class TabDrop {
  const TabDrop.onto(
    String this.targetId,
    this.zone, {
    this.targetExpanded = true,
  });

  /// Past the last row: the tab becomes the last root.
  const TabDrop.toEnd()
      : targetId = null,
        zone = TabDropZone.after,
        targetExpanded = false;

  final String? targetId;
  final TabDropZone zone;

  /// Whether the target's children are showing, which decides what "just
  /// below it" means.
  final bool targetExpanded;
}

/// What the system back gesture means at the start of the active tab's own
/// history (NAV-001, TAB-007).
enum TabBackAction {
  /// Root tab: the gesture is a no-op, exactly as before tabs existed.
  ignore,

  /// Child tab: close it, its parent takes the webview.
  closeAndActivateParent,
}

class TabLifecycleEngine {
  TabLifecycleEngine._();

  /// The shape the rest of the app may assume of a site's tabs: non-empty,
  /// unique ids, every `parentId` naming another tab in the list, and no
  /// parent cycles. [normalize] establishes it and every operation here that
  /// returns a tree keeps it.
  static bool wellFormed(List<SiteTab> tabs) {
    final byId = {for (final t in tabs) t.id: t};
    if (tabs.isEmpty || byId.length != tabs.length) return false;
    for (final t in tabs) {
      final seen = <String>{t.id};
      for (var p = t.parentId; p != null; p = byId[p]!.parentId) {
        if (!byId.containsKey(p) || !seen.add(p)) return false;
      }
    }
    return true;
  }

  /// [tabs] is [wellFormed] and [activeTabId] names one of them.
  static bool _wellFormedWith(List<SiteTab> tabs, String activeTabId) =>
      wellFormed(tabs) && tabs.any((t) => t.id == activeTabId);

  /// An operation keeps the shape: only a malformed input may come out
  /// malformed.
  static bool _kept(List<SiteTab> before, List<SiteTab> after) =>
      !wellFormed(before) || wellFormed(after);

  /// Coerce any tab list into a [wellFormed] one whose `activeTabId` names a
  /// member.
  ///
  /// Runs on every rehydrate because the list can arrive from an imported
  /// backup or a partial write, where none of that is guaranteed. A cycle is
  /// broken by rooting the tab that closes it rather than dropping it: a tab
  /// the user can still see in the list is recoverable, one silently deleted
  /// is not.
  static ({List<SiteTab> tabs, String activeTabId}) normalize(
    List<SiteTab>? tabs,
    String? activeTabId,
    String fallbackUrl,
  ) {
    final out = <SiteTab>[];
    final seen = <String>{};
    for (final t in tabs ?? const <SiteTab>[]) {
      if (!seen.add(t.id)) continue;
      out.add(t);
    }
    if (out.isEmpty) {
      final primary = SiteTab.primary(url: fallbackUrl);
      return (tabs: [primary], activeTabId: primary.id);
    }
    final byId = {for (final t in out) t.id: t};
    for (final t in out) {
      final parent = t.parentId;
      if (parent == null) continue;
      if (parent == t.id || !byId.containsKey(parent)) {
        t.parentId = null;
        continue;
      }
      // Walk up; a chain that comes back to this tab is a cycle.
      final path = <String>{t.id};
      var cursor = byId[parent];
      while (cursor != null) {
        if (!path.add(cursor.id)) {
          t.parentId = null;
          break;
        }
        final next = cursor.parentId;
        cursor = next == null ? null : byId[next];
      }
    }
    final active =
        activeTabId != null && byId.containsKey(activeTabId)
            ? activeTabId
            : out.first.id;
    assert(_wellFormedWith(out, active), 'normalize repairs every tree');
    return (tabs: out, activeTabId: active);
  }

  /// Depth-first tree order: roots in list order, each followed by its
  /// children in list order.
  static List<TabRow> treeOrder(List<SiteTab> tabs) {
    final childrenOf = <String, List<SiteTab>>{};
    final roots = <SiteTab>[];
    final ids = {for (final t in tabs) t.id};
    for (final t in tabs) {
      final parent = t.parentId;
      if (parent == null || !ids.contains(parent) || parent == t.id) {
        roots.add(t);
      } else {
        childrenOf.putIfAbsent(parent, () => <SiteTab>[]).add(t);
      }
    }
    final out = <TabRow>[];
    final visited = <String>{};
    void walk(SiteTab t, int depth) {
      if (!visited.add(t.id)) return;
      final kids = childrenOf[t.id] ?? const <SiteTab>[];
      out.add(TabRow(t, depth, childCount: kids.length));
      for (final c in kids) {
        walk(c, depth + 1);
      }
    }

    for (final r in roots) {
      walk(r, 0);
    }
    // Defensive: a tab left unvisited would vanish from every surface that
    // renders the tree, which is worse than showing it at the top level.
    for (final t in tabs) {
      if (!visited.contains(t.id)) out.add(TabRow(t, 0));
    }
    assert(!wellFormed(tabs) || out.length == tabs.length,
        'every tab of a well-formed tree is one row');
    return out;
  }

  /// The rows of [tabs] a site's list shows of another site's tree (TAB-017):
  /// every tab [keep] accepts with its whole subtree, and the tabs on the way
  /// down to it, each at its depth in the whole tree. The rest of the tree
  /// holds nothing kept; the caller counts it from the lengths.
  static List<TabRow> rowsAround(
    List<SiteTab> tabs,
    bool Function(SiteTab tab) keep,
  ) {
    final rows = treeOrder(tabs);
    final shown = List<bool>.filled(rows.length, false);
    // Tree order is depth-first, so the rows above one that are still open
    // (the path) are its ancestors, and everything below a kept row until
    // the depth climbs back to it is its subtree.
    final path = <int>[];
    int? keptDepth;
    for (var i = 0; i < rows.length; i++) {
      final depth = rows[i].depth;
      while (path.isNotEmpty && rows[path.last].depth >= depth) {
        path.removeLast();
      }
      if (keptDepth != null && depth <= keptDepth) keptDepth = null;
      if (keptDepth != null || keep(rows[i].tab)) {
        keptDepth ??= depth;
        shown[i] = true;
        for (final p in path) {
          shown[p] = true;
        }
      }
      path.add(i);
    }
    return [
      for (var i = 0; i < rows.length; i++)
        if (shown[i]) rows[i],
    ];
  }

  /// Every tab below [id], depth-first.
  static List<SiteTab> descendants(List<SiteTab> tabs, String id) {
    final childrenOf = <String, List<SiteTab>>{};
    for (final t in tabs) {
      final parent = t.parentId;
      if (parent != null) childrenOf.putIfAbsent(parent, () => []).add(t);
    }
    final out = <SiteTab>[];
    final seen = <String>{id};
    void walk(String from) {
      for (final c in childrenOf[from] ?? const <SiteTab>[]) {
        if (!seen.add(c.id)) continue;
        out.add(c);
        walk(c.id);
      }
    }

    walk(id);
    return out;
  }

  /// Insert [tab] after [parentId]'s last descendant, so the flat list already
  /// reads in tree order and a new child appears directly under the tab it was
  /// opened from rather than at the end of the site.
  static List<SiteTab> insertChild(List<SiteTab> tabs, SiteTab tab) {
    final parentId = tab.parentId;
    final out =
        parentId == null ? [...tabs, tab] : insertAfter(tabs, parentId, tab);
    assert(_kept(tabs, out), 'insertChild keeps the tree well-formed');
    return out;
  }

  /// Insert [tab] directly after [anchorId] and everything under it, which is
  /// where a duplicate of the anchor belongs: its next sibling (TAB-010).
  static List<SiteTab> insertAfter(
    List<SiteTab> tabs,
    String anchorId,
    SiteTab tab,
  ) {
    final anchorIndex = tabs.indexWhere((t) => t.id == anchorId);
    if (anchorIndex < 0) return [...tabs, tab];
    final subtree = {
      anchorId,
      ...descendants(tabs, anchorId).map((t) => t.id),
    };
    var at = anchorIndex + 1;
    while (at < tabs.length && subtree.contains(tabs[at].id)) {
      at++;
    }
    final out = [...tabs.take(at), tab, ...tabs.skip(at)];
    assert(_kept(tabs, out), 'insertAfter keeps the tree well-formed');
    return out;
  }

  /// Move [tabId] and everything under it (TAB-015, LIR-026): it becomes a
  /// child of [newParentId], or a root when that is null, placed just before
  /// its sibling [beforeId], just after its sibling [afterId]'s subtree, or
  /// after the new parent's subtree when neither is given. Only `parentId`
  /// and list positions change: no host, state key or active tab.
  ///
  /// Null when refused: an unknown tab, a parent or anchor inside the moved
  /// subtree, or an anchor that is not a child of the new parent.
  static List<SiteTab>? move(
    List<SiteTab> tabs,
    String tabId, {
    required String? newParentId,
    String? beforeId,
    String? afterId,
  }) {
    final byId = {for (final t in tabs) t.id: t};
    final moving = byId[tabId];
    if (moving == null) return null;
    final block = {tabId, ...descendants(tabs, tabId).map((t) => t.id)};
    if (newParentId != null &&
        (block.contains(newParentId) || !byId.containsKey(newParentId))) {
      return null;
    }
    for (final anchor in [beforeId, afterId]) {
      if (anchor == null) continue;
      final a = byId[anchor];
      if (a == null || block.contains(anchor) || a.parentId != newParentId) {
        return null;
      }
    }
    final moved = [for (final t in tabs) if (block.contains(t.id)) t];
    final rest = [for (final t in tabs) if (!block.contains(t.id)) t];
    // Siblings are ordered by list position alone, so a subtree need not be
    // contiguous; landing after its last member puts the block after it.
    int after(String id) {
      final members = {id, ...descendants(rest, id).map((t) => t.id)};
      var last = -1;
      for (var i = 0; i < rest.length; i++) {
        if (members.contains(rest[i].id)) last = i;
      }
      return last + 1;
    }

    final int at;
    if (beforeId != null) {
      at = rest.indexWhere((t) => t.id == beforeId);
    } else if (afterId != null) {
      at = after(afterId);
    } else if (newParentId != null) {
      at = after(newParentId);
    } else {
      at = rest.length;
    }
    final wasWellFormed = wellFormed(tabs);
    moving.parentId = newParentId;
    final out = [...rest.take(at), ...moved, ...rest.skip(at)];
    assert(!wasWellFormed || wellFormed(out),
        'move keeps the tree well-formed');
    return out;
  }

  /// "Move under..." (LIR-026): [tabId] and its subtree become the last
  /// children of [newParentId], or the last root.
  static List<SiteTab>? reparent(
    List<SiteTab> tabs,
    String tabId,
    String? newParentId,
  ) =>
      move(tabs, tabId, newParentId: newParentId);

  /// [tabId] dropped in the tab list (TAB-015). Null when refused, which is a
  /// drop on the dragged tab or inside its own subtree.
  static List<SiteTab>? drop(List<SiteTab> tabs, String tabId, TabDrop drop) {
    final targetId = drop.targetId;
    if (targetId == null) return move(tabs, tabId, newParentId: null);
    if (targetId == tabId) return null;
    final target = tabs.where((t) => t.id == targetId).firstOrNull;
    if (target == null) return null;
    switch (drop.zone) {
      case TabDropZone.before:
        return move(tabs, tabId,
            newParentId: target.parentId, beforeId: targetId);
      case TabDropZone.into:
        return move(tabs, tabId, newParentId: targetId);
      case TabDropZone.after:
        if (drop.targetExpanded) {
          final first =
              tabs.where((t) => t.parentId == targetId).firstOrNull;
          if (first != null) {
            if (first.id == tabId) return [...tabs];
            return move(tabs, tabId, newParentId: targetId, beforeId: first.id);
          }
        }
        return move(tabs, tabId,
            newParentId: target.parentId, afterId: targetId);
    }
  }

  /// Close one tab. Its children move up to its parent (TAB-007) so nothing is
  /// orphaned by a close, and the tab that takes over is its parent when it
  /// had one, else the most recently active survivor.
  static TabCloseResult closeTab(
    List<SiteTab> tabs,
    String activeTabId,
    String closeId,
  ) =>
      _close(tabs, activeTabId, {closeId}, reparent: true);

  /// Close a tab and everything under it.
  static TabCloseResult closeSubtree(
    List<SiteTab> tabs,
    String activeTabId,
    String closeId,
  ) =>
      _close(
        tabs,
        activeTabId,
        {closeId, ...descendants(tabs, closeId).map((t) => t.id)},
        reparent: false,
      );

  static TabCloseResult _close(
    List<SiteTab> tabs,
    String activeTabId,
    Set<String> closeIds,
    {required bool reparent}) {
    final doomed = closeIds.where((id) => tabs.any((t) => t.id == id)).toSet();
    if (doomed.isEmpty) {
      return TabCloseResult(
        tabs: tabs,
        nextActiveId: activeTabId,
        closedIds: const [],
        activeChanged: false,
      );
    }
    final wasWellFormed = _wellFormedWith(tabs, activeTabId);
    final byId = {for (final t in tabs) t.id: t};
    final survivors = tabs.where((t) => !doomed.contains(t.id)).toList();
    if (reparent) {
      for (final t in survivors) {
        var parent = t.parentId;
        // Walk past any closed ancestor, so a chain of closes still lands the
        // survivor on a tab that exists.
        final guard = <String>{t.id};
        while (parent != null && doomed.contains(parent)) {
          if (!guard.add(parent)) {
            parent = null;
            break;
          }
          parent = byId[parent]?.parentId;
        }
        t.parentId = parent;
      }
    } else {
      for (final t in survivors) {
        if (t.parentId != null && doomed.contains(t.parentId)) {
          t.parentId = null;
        }
      }
    }
    final activeClosed = doomed.contains(activeTabId);
    assert(!wasWellFormed || survivors.isEmpty || wellFormed(survivors),
        'a close keeps the surviving tree well-formed');
    if (survivors.isEmpty) {
      return TabCloseResult(
        tabs: survivors,
        nextActiveId: null,
        closedIds: doomed.toList(),
        activeChanged: true,
      );
    }
    if (!activeClosed) {
      return TabCloseResult(
        tabs: survivors,
        nextActiveId: activeTabId,
        closedIds: doomed.toList(),
        activeChanged: false,
      );
    }
    final parentId = byId[activeTabId]?.parentId;
    String next;
    if (parentId != null && survivors.any((t) => t.id == parentId)) {
      next = parentId;
    } else {
      final byRecency = [...survivors]
        ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
      next = byRecency.first.id;
    }
    return TabCloseResult(
      tabs: survivors,
      nextActiveId: next,
      closedIds: doomed.toList(),
      activeChanged: true,
    );
  }

  /// Close every tab [shouldClose] names, with TAB-007's re-parenting. Used
  /// for hosted tabs whose host is gone or may no longer host (LIR-023).
  static TabCloseResult closeWhere(
    List<SiteTab> tabs,
    String activeTabId,
    bool Function(SiteTab tab) shouldClose,
  ) =>
      _close(
        tabs,
        activeTabId,
        {for (final t in tabs) if (shouldClose(t)) t.id},
        reparent: true,
      );

  /// The tab an owner URL may load into (LIR-018): [activeTabId] when the
  /// owner runs it itself inside its own domain, else its nearest such
  /// ancestor, else null (the caller opens a new root tab at the owner's
  /// home). [isForeign] marks a tab the owner runs in another domain
  /// (LIR-034), which an owner URL must not load into either.
  static String? ownerRunTab(
    List<SiteTab> tabs,
    String activeTabId, {
    bool Function(SiteTab tab)? isForeign,
  }) {
    final byId = {for (final t in tabs) t.id: t};
    final seen = <String>{};
    String? id = activeTabId;
    while (id != null && seen.add(id)) {
      final tab = byId[id];
      if (tab == null) return null;
      if (tab.hostSiteId == null && !(isForeign?.call(tab) ?? false)) {
        return tab.id;
      }
      id = tab.parentId;
    }
    return null;
  }

  /// What a back gesture means once the active tab's own history is exhausted.
  ///
  /// A tab the user opened from another tab closes and hands back to its
  /// parent, which is what a browser does with a tab opened from a link. A
  /// root tab keeps NAV-001's no-op: the gesture never leaves the app and
  /// never opens the drawer.
  static TabBackAction backAtHistoryStart(
    List<SiteTab> tabs,
    String activeTabId,
  ) {
    final active = tabs.where((t) => t.id == activeTabId).firstOrNull;
    final parentId = active?.parentId;
    if (parentId == null) return TabBackAction.ignore;
    if (!tabs.any((t) => t.id == parentId)) return TabBackAction.ignore;
    return TabBackAction.closeAndActivateParent;
  }

  /// Whether [url] is the site's home page for TAB-014: [initUrl] up to an
  /// https upgrade, host case, a trailing slash and the fragment, none of
  /// which make it a different page.
  static bool isHomeUrl(String url, String initUrl) {
    final a = Uri.tryParse(url);
    final b = Uri.tryParse(initUrl);
    if (a == null || b == null) return url == initUrl;
    String path(Uri u) {
      final p = u.path;
      if (p.isEmpty) return '/';
      return p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    }

    final schemes = {a.scheme.toLowerCase(), b.scheme.toLowerCase()};
    final sameScheme = schemes.length == 1 ||
        (schemes.length == 2 && schemes.containsAll(const ['http', 'https']));
    return sameScheme &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        (a.hasPort ? a.port : null) == (b.hasPort ? b.port : null) &&
        path(a) == path(b) &&
        a.query == b.query;
  }

  /// Where a site with tabs lands when it is entered with Always open Home on
  /// (TAB-014): a tab at its home page that the site runs itself (LIR-018).
  /// Null when the active tab is already there. Otherwise the most recently
  /// used parked tab at home, or failing that a new root tab at [initUrl],
  /// appended. Either way the tab the site was on is kept.
  static ({List<SiteTab> tabs, String activeTabId})? homeLanding(
    List<SiteTab> tabs,
    String activeTabId,
    String initUrl,
  ) {
    bool ownHome(SiteTab t) =>
        t.hostSiteId == null && isHomeUrl(t.url, initUrl);
    final active = tabs.where((t) => t.id == activeTabId).firstOrNull;
    if (active != null && ownHome(active)) return null;
    SiteTab? home;
    for (final t in tabs) {
      if (t.id == activeTabId || !ownHome(t)) continue;
      if (home == null || t.lastActiveAt.isAfter(home.lastActiveAt)) home = t;
    }
    final ({List<SiteTab> tabs, String activeTabId}) landing;
    if (home != null) {
      landing = (tabs: tabs, activeTabId: home.id);
    } else {
      final fresh = SiteTab(url: initUrl);
      landing = (tabs: [...tabs, fresh], activeTabId: fresh.id);
    }
    assert(
        !wellFormed(tabs) || _wellFormedWith(landing.tabs, landing.activeTabId),
        'a home landing keeps the tree well-formed');
    return landing;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
