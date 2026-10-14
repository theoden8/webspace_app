import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_list_engine.dart';

/// TAB-017: which other trees a site's list shows, and in what order.
void main() {
  /// A tree of [tabs] whose host id (or [owner]) is the site a tab runs as.
  TabTree tree(SiteId owner, {required List<SiteTab> tabs}) =>
      TabTree(owner, tabs: tabs, runsAs: (t) => t.hostSiteId ?? owner);

  SiteTab tab(TabId id, {TabId? parent, SiteId? runsAs}) => SiteTab(
      id: id, url: 'https://x.example/$id', parentId: parent, hostSiteId: runsAs);

  // The example branch: ddg > gh > hf, in DuckDuckGo's tree, gh on screen.
  final branchTree = tree(SiteId('ddg'), tabs: [
    tab(TabId('d')),
    tab(TabId('g'), parent: TabId('d'), runsAs: SiteId('gh')),
    tab(TabId('h'), parent: TabId('g'), runsAs: SiteId('hf')),
    tab(TabId('d2'), parent: TabId('d')),
  ]);

  group('branchContainers', () {
    test('the sites from the root down through what was opened below', () {
      expect(TabListEngine.branchContainers(branchTree, activeTabId: TabId('g')),
          ['ddg', 'gh', 'hf']);
    });

    test('a sibling is not on the branch', () {
      expect(TabListEngine.branchContainers(branchTree, activeTabId: TabId('h')),
          ['ddg', 'gh', 'hf']);
      expect(TabListEngine.branchContainers(branchTree, activeTabId: TabId('d2')),
          ['ddg']);
    });

    test('the root takes in the whole tree', () {
      expect(TabListEngine.branchContainers(branchTree, activeTabId: TabId('d')),
          ['ddg', 'gh', 'hf']);
    });

    test('a missing tab and a parent cycle end the walk', () {
      expect(TabListEngine.branchContainers(branchTree, activeTabId: TabId('gone')),
          isEmpty);
      final cycle = tree(SiteId('ddg'), tabs: [
        tab(TabId('a'), parent: TabId('b'), runsAs: SiteId('gh')),
        tab(TabId('b'), parent: TabId('a')),
      ]);
      expect(TabListEngine.branchContainers(cycle, activeTabId: TabId('a')).toSet(),
          {'ddg', 'gh'});
    });
  });

  group('otherTrees', () {
    List<String> ids(List<ListedTree> trees) => [for (final t in trees) t.siteId];

    test('each tree holding one of the branch\'s sites, in branch order', () {
      final others = [
        tree(SiteId('wiki'), tabs: [tab(TabId('w'), runsAs: SiteId('hf'))]),
        tree(SiteId('mastodon'), tabs: [tab(TabId('m'))]),
        tree(SiteId('news'), tabs: [tab(TabId('n'), runsAs: SiteId('gh'))]),
        tree(SiteId('blog'), tabs: [tab(TabId('b'), runsAs: SiteId('ddg'))]),
      ];
      expect(
        ids(TabListEngine.otherTrees(
            containers: [SiteId('ddg'), SiteId('gh'), SiteId('hf')], selected: SiteId('gh'), others: others)),
        ['blog', 'news', 'wiki'],
        reason: 'ddg first, then gh, then hf; nothing for mastodon',
      );
    });

    test('a tree is placed by the earliest site it holds, then as given', () {
      final others = [
        tree(SiteId('a'), tabs: [tab(TabId('a1'), runsAs: SiteId('hf')), tab(TabId('a2'), runsAs: SiteId('gh'))]),
        tree(SiteId('b'), tabs: [tab(TabId('b1'), runsAs: SiteId('gh'))]),
      ];
      expect(
        ids(TabListEngine.otherTrees(
            containers: [SiteId('ddg'), SiteId('gh'), SiteId('hf')], selected: SiteId('gh'), others: others)),
        ['a', 'b'],
      );
    });

    test('more than five branches follow only the tab on screen\'s site', () {
      final others = [
        for (var i = 0; i < 5; i++)
          tree(SiteId('s$i'), tabs: [tab(TabId('x$i'), runsAs: SiteId('hf'))]),
        tree(SiteId('gh-elsewhere'), tabs: [tab(TabId('y'), runsAs: SiteId('gh'))]),
      ];
      expect(
        TabListEngine.branchCount(others, followed: {SiteId('ddg'), SiteId('gh'), SiteId('hf')}),
        6,
      );
      expect(
        ids(TabListEngine.otherTrees(
            containers: [SiteId('ddg'), SiteId('gh'), SiteId('hf')], selected: SiteId('gh'), others: others)),
        ['gh-elsewhere'],
      );
    });

    test('five branches are all listed', () {
      final others = [
        for (var i = 0; i < 4; i++)
          tree(SiteId('s$i'), tabs: [tab(TabId('x$i'), runsAs: SiteId('hf'))]),
        tree(SiteId('gh-elsewhere'), tabs: [tab(TabId('y'), runsAs: SiteId('gh'))]),
      ];
      expect(
        TabListEngine.otherTrees(
            containers: [SiteId('ddg'), SiteId('gh'), SiteId('hf')], selected: SiteId('gh'), others: others),
        hasLength(5),
      );
    });

    test('a branch inside a branch counts once, since it is listed whole', () {
      final nested = tree(SiteId('t'), tabs: [
        tab(TabId('r'), runsAs: SiteId('gh')),
        tab(TabId('mid'), parent: TabId('r')),
        tab(TabId('deep'), parent: TabId('mid'), runsAs: SiteId('gh')),
        tab(TabId('other')),
        tab(TabId('again'), parent: TabId('other'), runsAs: SiteId('gh')),
      ]);
      expect(TabListEngine.branchCount([nested], followed: {SiteId('gh')}), 2);
    });

    test('where the user was is listed, last and uncounted', () {
      final others = [
        tree(SiteId('wiki'), tabs: [tab(TabId('w0')), tab(TabId('w'), parent: TabId('w0'))]),
        tree(SiteId('news'), tabs: [tab(TabId('n'), runsAs: SiteId('gh'))]),
      ];
      final listed = TabListEngine.otherTrees(
        containers: [SiteId('gh')],
        selected: SiteId('gh'),
        others: others,
        keep: (site, {required tab}) => site == 'wiki' && tab.id == 'w',
      );
      expect(ids(listed), ['news', 'wiki']);
      expect([for (final r in listed.last.rows) r.tab.id], ['w0', 'w']);
    });

    test('rows are folded around what is followed', () {
      final listed = TabListEngine.otherTrees(
        containers: [SiteId('ddg')],
        selected: SiteId('ddg'),
        others: [
          tree(SiteId('gh'), tabs: [
            tab(TabId('root')),
            tab(TabId('hosted'), parent: TabId('root'), runsAs: SiteId('ddg')),
            tab(TabId('below'), parent: TabId('hosted')),
            tab(TabId('own'), parent: TabId('root')),
          ]),
        ],
      );
      expect([for (final r in listed.single.rows) r.tab.id],
          ['root', 'hosted', 'below']);
    });
  });
}
