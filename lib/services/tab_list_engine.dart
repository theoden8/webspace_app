/// What the Tabs sheet's This site view lists after the site's own tree.
///
/// Spec: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md`
/// (TAB-017). The branch through the tab on screen names the containers that
/// matter: the sites its tabs run as, from its root down through everything
/// opened below it. Every other site's tree holding a tab that runs as one of
/// them is listed, folded around those tabs, in branch order; when that comes
/// to more than [TabListEngine.maxBranches] branches, only the on-screen
/// tab's own container is followed.
library;

import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';

/// One site's tree as the list sees it.
class TabTree {
  const TabTree(this.siteId, {required this.tabs, required this.runsAs});

  final String siteId;
  final List<SiteTab> tabs;

  /// The site [tab] runs as.
  final String Function(SiteTab tab) runsAs;
}

/// A tree the list shows, folded to [rows].
class ListedTree {
  const ListedTree(this.siteId, {required this.rows});

  final String siteId;
  final List<TabRow> rows;
}

abstract final class TabListEngine {
  /// Past this many branches in other trees, only the on-screen tab's
  /// container is followed.
  static const int maxBranches = 5;

  /// The sites the branch through [activeTabId] runs as, each once: its
  /// ancestors from the root, the tab itself, then what was opened below it.
  static List<String> branchContainers(TabTree tree,
      {required String activeTabId}) {
    final byId = {for (final t in tree.tabs) t.id: t};
    final active = byId[activeTabId];
    if (active == null) return const [];
    final up = <SiteTab>[];
    final seen = <String>{};
    for (var t = active; seen.add(t.id);) {
      up.add(t);
      final parent = byId[t.parentId];
      if (parent == null) break;
      t = parent;
    }
    final out = <String>[];
    for (final t in [
      ...up.reversed,
      ...TabLifecycleEngine.descendants(tree.tabs, id: activeTabId),
    ]) {
      final site = tree.runsAs(t);
      if (!out.contains(site)) out.add(site);
    }
    return out;
  }

  /// Each tree of [others] that holds a tab running as one of [containers],
  /// folded to those tabs, their subtrees and the tabs above them, and
  /// ordered by the first of [containers] it holds, then as given. With more
  /// than [maxBranches] branches in all, only [selected] is followed. A tab
  /// [keep] accepts is listed whatever it runs as, and is not counted.
  static List<ListedTree> otherTrees({
    required List<String> containers,
    required String selected,
    required List<TabTree> others,
    bool Function(String siteId, {required SiteTab tab})? keep,
  }) {
    var followed = containers.toSet();
    if (branchCount(others, followed: followed) > maxBranches) {
      followed = {selected};
    }
    final listed = <(int, int, ListedTree)>[];
    for (final (order, tree) in others.indexed) {
      bool held(SiteTab t) => followed.contains(tree.runsAs(t));
      final rows = TabLifecycleEngine.rowsAround(
        tree.tabs,
        keep: (t) => held(t) || (keep?.call(tree.siteId, tab: t) ?? false),
      );
      if (rows.isEmpty) continue;
      var rank = containers.length;
      for (final t in tree.tabs) {
        if (!held(t)) continue;
        final i = containers.indexOf(tree.runsAs(t));
        if (i >= 0 && i < rank) rank = i;
      }
      listed.add((rank, order, ListedTree(tree.siteId, rows: rows)));
    }
    listed.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    return [for (final (_, _, tree) in listed) tree];
  }

  /// How many branches [trees] hold for [followed]: tabs running as one of
  /// them with no such tab above them, since a branch is listed whole.
  static int branchCount(List<TabTree> trees, {required Set<String> followed}) {
    var n = 0;
    for (final tree in trees) {
      int? inside;
      for (final row in TabLifecycleEngine.treeOrder(tree.tabs)) {
        if (inside != null && row.depth <= inside) inside = null;
        if (inside == null && followed.contains(tree.runsAs(row.tab))) {
          n++;
          inside = row.depth;
        }
      }
    }
    return n;
  }
}
