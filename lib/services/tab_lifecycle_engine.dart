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
/// [nextActiveId] names the tab that should take the webview, or null when the
/// list emptied and the caller must seed a fresh home tab.
class TabCloseResult {
  const TabCloseResult({
    required this.tabs,
    required this.nextActiveId,
    required this.closedIds,
    required this.activeChanged,
  });

  final List<SiteTab> tabs;
  final String? nextActiveId;

  /// Every tab removed, so the caller can drop each one's saved state bytes.
  final List<String> closedIds;

  /// Whether the webview has to be re-bound. False when the closed tabs were
  /// all parked: nothing on screen changed, so no capture/dispose/restore.
  final bool activeChanged;
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

  /// Coerce any tab list into the shape the rest of the app may assume:
  /// non-empty, unique ids, every `parentId` naming another tab in the list,
  /// no parent cycles, and an `activeTabId` that names a member.
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
    return (tabs: out, activeTabId: active);
  }

  /// Depth-first tree order: roots in list order, each followed by its
  /// children in list order. Every tab appears exactly once — [normalize] has
  /// already rooted anything whose parent is missing or cyclic.
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
    return out;
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
    if (parentId == null) return [...tabs, tab];
    final parentIndex = tabs.indexWhere((t) => t.id == parentId);
    if (parentIndex < 0) return [...tabs, tab];
    final subtree = {
      parentId,
      ...descendants(tabs, parentId).map((t) => t.id),
    };
    var at = parentIndex + 1;
    while (at < tabs.length && subtree.contains(tabs[at].id)) {
      at++;
    }
    return [...tabs.take(at), tab, ...tabs.skip(at)];
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

  /// Close every parked tab, keeping the active one.
  static TabCloseResult closeParked(List<SiteTab> tabs, String activeTabId) =>
      _close(
        tabs,
        activeTabId,
        tabs.map((t) => t.id).where((id) => id != activeTabId).toSet(),
        reparent: true,
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
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
