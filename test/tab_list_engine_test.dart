import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_list_engine.dart';

/// TAB-017: which other trees a site's list shows, and in what order.
void main() {
  /// A tree of [tabs] whose host id (or [owner]) is the site a tab runs as.
  TabTree tree(String owner, List<SiteTab> tabs) =>
      TabTree(owner, tabs, (t) => t.hostSiteId ?? owner);

  SiteTab tab(String id, {String? parent, String? runsAs}) => SiteTab(
      id: id, url: 'https://x.example/$id', parentId: parent, hostSiteId: runsAs);

  // The example branch: ddg > gh > hf, in DuckDuckGo's tree, gh on screen.
  final branchTree = tree('ddg', [
    tab('d'),
    tab('g', parent: 'd', runsAs: 'gh'),
    tab('h', parent: 'g', runsAs: 'hf'),
    tab('d2', parent: 'd'),
  ]);

  group('branchContainers', () {
    test('the sites from the root down through what was opened below', () {
      expect(TabListEngine.branchContainers(branchTree, 'g'), ['ddg', 'gh', 'hf']);
    });

    test('a sibling is not on the branch', () {
      expect(TabListEngine.branchContainers(branchTree, 'h'), ['ddg', 'gh', 'hf']);
      expect(TabListEngine.branchContainers(branchTree, 'd2'), ['ddg']);
    });

    test('the root takes in the whole tree', () {
      expect(TabListEngine.branchContainers(branchTree, 'd'), ['ddg', 'gh', 'hf']);
    });

    test('a missing tab and a parent cycle end the walk', () {
      expect(TabListEngine.branchContainers(branchTree, 'gone'), isEmpty);
      final cycle = tree('ddg', [
        tab('a', parent: 'b', runsAs: 'gh'),
        tab('b', parent: 'a'),
      ]);
      expect(TabListEngine.branchContainers(cycle, 'a').toSet(), {'ddg', 'gh'});
    });
  });

  group('otherTrees', () {
    List<String> ids(List<ListedTree> trees) => [for (final t in trees) t.siteId];

    test('each tree holding one of the branch\'s sites, in branch order', () {
      final others = [
        tree('wiki', [tab('w', runsAs: 'hf')]),
        tree('mastodon', [tab('m')]),
        tree('news', [tab('n', runsAs: 'gh')]),
        tree('blog', [tab('b', runsAs: 'ddg')]),
      ];
      expect(
        ids(TabListEngine.otherTrees(
            containers: ['ddg', 'gh', 'hf'], selected: 'gh', others: others)),
        ['blog', 'news', 'wiki'],
        reason: 'ddg first, then gh, then hf; nothing for mastodon',
      );
    });

    test('a tree is placed by the earliest site it holds, then as given', () {
      final others = [
        tree('a', [tab('a1', runsAs: 'hf'), tab('a2', runsAs: 'gh')]),
        tree('b', [tab('b1', runsAs: 'gh')]),
      ];
      expect(
        ids(TabListEngine.otherTrees(
            containers: ['ddg', 'gh', 'hf'], selected: 'gh', others: others)),
        ['a', 'b'],
      );
    });

    test('more than five branches follow only the tab on screen\'s site', () {
      final others = [
        for (var i = 0; i < 5; i++) tree('s$i', [tab('x$i', runsAs: 'hf')]),
        tree('gh-elsewhere', [tab('y', runsAs: 'gh')]),
      ];
      expect(
        TabListEngine.branchCount(others, {'ddg', 'gh', 'hf'}),
        6,
      );
      expect(
        ids(TabListEngine.otherTrees(
            containers: ['ddg', 'gh', 'hf'], selected: 'gh', others: others)),
        ['gh-elsewhere'],
      );
    });

    test('five branches are all listed', () {
      final others = [
        for (var i = 0; i < 4; i++) tree('s$i', [tab('x$i', runsAs: 'hf')]),
        tree('gh-elsewhere', [tab('y', runsAs: 'gh')]),
      ];
      expect(
        TabListEngine.otherTrees(
            containers: ['ddg', 'gh', 'hf'], selected: 'gh', others: others),
        hasLength(5),
      );
    });

    test('a branch inside a branch counts once, since it is listed whole', () {
      final nested = tree('t', [
        tab('r', runsAs: 'gh'),
        tab('mid', parent: 'r'),
        tab('deep', parent: 'mid', runsAs: 'gh'),
        tab('other'),
        tab('again', parent: 'other', runsAs: 'gh'),
      ]);
      expect(TabListEngine.branchCount([nested], {'gh'}), 2);
    });

    test('where the user was is listed, last and uncounted', () {
      final others = [
        tree('wiki', [tab('w0'), tab('w', parent: 'w0')]),
        tree('news', [tab('n', runsAs: 'gh')]),
      ];
      final listed = TabListEngine.otherTrees(
        containers: ['gh'],
        selected: 'gh',
        others: others,
        keep: (site, t) => site == 'wiki' && t.id == 'w',
      );
      expect(ids(listed), ['news', 'wiki']);
      expect([for (final r in listed.last.rows) r.tab.id], ['w0', 'w']);
    });

    test('rows are folded around what is followed', () {
      final listed = TabListEngine.otherTrees(
        containers: ['ddg'],
        selected: 'ddg',
        others: [
          tree('gh', [
            tab('root'),
            tab('hosted', parent: 'root', runsAs: 'ddg'),
            tab('below', parent: 'hosted'),
            tab('own', parent: 'root'),
          ]),
        ],
      );
      expect([for (final r in listed.single.rows) r.tab.id],
          ['root', 'hosted', 'below']);
    });
  });
}
