import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';

SiteTab tab(TabId id, {TabId? parent, String? url, int? activeAt}) => SiteTab(
      id: id,
      url: url ?? 'https://example.org/$id',
      parentId: parent,
      lastActiveAt: activeAt == null
          ? DateTime(2026, 1, 1)
          : DateTime.fromMillisecondsSinceEpoch(activeAt),
    );

List<String> ids(List<SiteTab> tabs) => tabs.map((t) => t.id).toList();

void main() {
  group('wellFormed', () {
    test('accepts a tree', () {
      expect(
          TabLifecycleEngine.wellFormed(
              [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'), parent: TabId('b'))]),
          isTrue);
    });

    test('rejects each shape normalize repairs', () {
      for (final (name, tabs) in [
        ('empty', <SiteTab>[]),
        ('duplicate id', [tab(TabId('a')), tab(TabId('a'))]),
        ('missing parent', [tab(TabId('a'), parent: TabId('ghost'))]),
        ('own parent', [tab(TabId('a'), parent: TabId('a'))]),
        ('cycle', [tab(TabId('r')), tab(TabId('a'), parent: TabId('b')), tab(TabId('b'), parent: TabId('a'))]),
      ]) {
        expect(TabLifecycleEngine.wellFormed(tabs), isFalse, reason: name);
      }
    });
  });

  group('normalize (TAB-001)', () {
    test('an empty list becomes one primary tab at the fallback url', () {
      final r = TabLifecycleEngine.normalize(null,
          activeTabId: null, fallbackUrl: 'https://site.test/');
      expect(r.tabs, hasLength(1));
      expect(r.tabs.single.id, kPrimaryTabId);
      expect(r.tabs.single.url, 'https://site.test/');
      expect(r.activeTabId, kPrimaryTabId);
    });

    test('duplicate ids collapse to the first occurrence', () {
      final r = TabLifecycleEngine.normalize(
          [tab(TabId('a')), tab(TabId('a'), url: 'https://other.test/'), tab(TabId('b'))],
          activeTabId: TabId('b'),
          fallbackUrl: 'https://site.test/');
      expect(ids(r.tabs), ['a', 'b']);
      expect(r.tabs.first.url, 'https://example.org/a');
    });

    test('a parent that is not in the list is dropped, the tab is kept', () {
      final r = TabLifecycleEngine.normalize([tab(TabId('a'), parent: TabId('ghost'))],
          activeTabId: TabId('a'), fallbackUrl: 'https://site.test/');
      expect(ids(r.tabs), ['a']);
      expect(r.tabs.single.parentId, isNull);
    });

    test('a parent cycle is broken without losing a tab', () {
      final r = TabLifecycleEngine.normalize(
          [tab(TabId('a'), parent: TabId('b')), tab(TabId('b'), parent: TabId('a'))],
          activeTabId: TabId('a'),
          fallbackUrl: 'https://site.test/');
      expect(ids(r.tabs), ['a', 'b']);
      // Whichever way the cycle is cut, walking parents must terminate.
      expect(TabLifecycleEngine.treeOrder(r.tabs), hasLength(2));
    });

    test('a tab that is its own parent is rooted', () {
      final r = TabLifecycleEngine.normalize([tab(TabId('a'), parent: TabId('a'))],
          activeTabId: TabId('a'), fallbackUrl: 'https://site.test/');
      expect(r.tabs.single.parentId, isNull);
    });

    test('an activeTabId naming nothing falls back to the first tab', () {
      final r = TabLifecycleEngine.normalize([tab(TabId('a')), tab(TabId('b'))],
          activeTabId: TabId('ghost'), fallbackUrl: 'https://site.test/');
      expect(r.activeTabId, 'a');
    });
  });

  group('treeOrder (TAB-008)', () {
    test('children follow their parent, indented by depth', () {
      final tabs = [
        tab(TabId('a')),
        tab(TabId('b'), parent: TabId('a')),
        tab(TabId('c'), parent: TabId('b')),
        tab(TabId('d')),
      ];
      final rows = TabLifecycleEngine.treeOrder(tabs);
      expect(rows.map((r) => r.tab.id).toList(), ['a', 'b', 'c', 'd']);
      expect(rows.map((r) => r.depth).toList(), [0, 1, 2, 0]);
    });

    test('childCount counts direct children only', () {
      final rows = TabLifecycleEngine.treeOrder([
        tab(TabId('a')),
        tab(TabId('b'), parent: TabId('a')),
        tab(TabId('c'), parent: TabId('a')),
        tab(TabId('d'), parent: TabId('b')),
      ]);
      expect(rows.firstWhere((r) => r.tab.id == 'a').childCount, 2);
      expect(rows.firstWhere((r) => r.tab.id == 'b').childCount, 1);
    });

    test('every tab appears exactly once', () {
      final tabs = [
        tab(TabId('a')),
        tab(TabId('b'), parent: TabId('a')),
        tab(TabId('c'), parent: TabId('ghost')),
      ];
      final rows = TabLifecycleEngine.treeOrder(tabs);
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.tab.id).toSet(), {'a', 'b', 'c'});
    });
  });

  group('insertChild', () {
    test('a child lands directly after its parent', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'))];
      final out =
          TabLifecycleEngine.insertChild(tabs, tab: tab(TabId('c'), parent: TabId('a')));
      expect(ids(out), ['a', 'c', 'b']);
    });

    test('a second child lands after the first subtree, not inside it', () {
      var tabs = [tab(TabId('a')), tab(TabId('b'))];
      tabs = TabLifecycleEngine.insertChild(tabs, tab: tab(TabId('c'), parent: TabId('a')));
      tabs = TabLifecycleEngine.insertChild(tabs, tab: tab(TabId('d'), parent: TabId('c')));
      tabs = TabLifecycleEngine.insertChild(tabs, tab: tab(TabId('e'), parent: TabId('a')));
      expect(ids(tabs), ['a', 'c', 'd', 'e', 'b']);
      expect(
        TabLifecycleEngine.treeOrder(tabs).map((r) => r.depth).toList(),
        [0, 1, 2, 1, 0],
      );
    });

    test('insertAfter lands after the anchor\'s whole subtree', () {
      var tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'))];
      tabs = TabLifecycleEngine.insertAfter(tabs, anchorId: TabId('a'), tab: tab(TabId('d')));
      expect(ids(tabs), ['a', 'b', 'd', 'c']);
    });

    test('a duplicate of a child stays a sibling under the same parent', () {
      var tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'), parent: TabId('a'))];
      tabs = TabLifecycleEngine.insertAfter(tabs,
          anchorId: TabId('b'), tab: tab(TabId('b2'), parent: TabId('a')));
      expect(ids(tabs), ['a', 'b', 'b2', 'c']);
      expect(
        TabLifecycleEngine.treeOrder(tabs).map((r) => r.depth).toList(),
        [0, 1, 1, 1],
      );
    });

    test('a root tab goes to the end', () {
      final out = TabLifecycleEngine.insertChild([tab(TabId('a'))], tab: tab(TabId('z')));
      expect(ids(out), ['a', 'z']);
    });
  });

  group('move and drop (TAB-015, LIR-026)', () {
    List<int> depths(List<SiteTab> tabs) =>
        TabLifecycleEngine.treeOrder(tabs).map((r) => r.depth).toList();

    test('re-parenting lands the tab directly under the new parent\'s subtree',
        () {
      final tabs = [tab(TabId('a')), tab(TabId('b')), tab(TabId('c'))];
      final out =
          TabLifecycleEngine.reparent(tabs, tabId: TabId('c'), newParentId: TabId('a'))!;
      expect(ids(out), ['a', 'c', 'b']);
      expect(out.firstWhere((t) => t.id == 'c').parentId, 'a');
    });

    test('a tab cannot move under its own descendant', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a'))];
      expect(TabLifecycleEngine.reparent(tabs, tabId: TabId('a'), newParentId: TabId('b')),
          isNull);
      expect(
          TabLifecycleEngine.drop(tabs,
              tabId: TabId('a'),
              drop: TabDrop.onto(TabId('b'), zone: TabDropZone.into)),
          isNull);
      expect(TabLifecycleEngine.drop(tabs, tabId: TabId('a'),
          drop: TabDrop.onto(TabId('a'), zone: TabDropZone.before)), isNull);
      expect(tabs.first.parentId, isNull, reason: 'a refusal changes nothing');
    });

    test('before a row makes a sibling in front of it', () {
      final tabs = [tab(TabId('a')), tab(TabId('b')), tab(TabId('c'))];
      final out = TabLifecycleEngine.drop(tabs,
          tabId: TabId('c'), drop: TabDrop.onto(TabId('a'), zone: TabDropZone.before))!;
      expect(ids(out), ['c', 'a', 'b']);
    });

    test('into a row makes the last child, and the subtree comes along', () {
      final tabs = [tab(TabId('a')), tab(TabId('x'), parent: TabId('a')), tab(TabId('b')),
          tab(TabId('c'), parent: TabId('b'))];
      final out = TabLifecycleEngine.drop(tabs,
          tabId: TabId('b'), drop: TabDrop.onto(TabId('a'), zone: TabDropZone.into))!;
      expect(ids(out), ['a', 'x', 'b', 'c']);
      expect(out.firstWhere((t) => t.id == 'b').parentId, 'a');
      expect(out.firstWhere((t) => t.id == 'c').parentId, 'b');
      expect(depths(out), [0, 1, 1, 2]);
    });

    test('below an expanded parent is its first child', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'))];
      final out = TabLifecycleEngine.drop(tabs,
          tabId: TabId('c'), drop: TabDrop.onto(TabId('a'), zone: TabDropZone.after))!;
      expect(ids(out), ['a', 'c', 'b']);
      expect(out.firstWhere((t) => t.id == 'c').parentId, 'a');
      expect(depths(out), [0, 1, 1]);
    });

    test('below a collapsed parent is its sibling after the whole subtree', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c')), tab(TabId('d'))];
      final out = TabLifecycleEngine.drop(tabs,
          tabId: TabId('d'),
          drop: TabDrop.onto(TabId('a'),
              zone: TabDropZone.after, targetExpanded: false))!;
      expect(ids(out), ['a', 'b', 'd', 'c']);
      expect(out.firstWhere((t) => t.id == 'd').parentId, isNull);
    });

    test('a child dropped just below its parent stays where it is', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'), parent: TabId('a'))];
      final out = TabLifecycleEngine.drop(tabs,
          tabId: TabId('b'), drop: TabDrop.onto(TabId('a'), zone: TabDropZone.after))!;
      expect(ids(out), ['a', 'b', 'c']);
    });

    test('past the last row the tab becomes the last root', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'))];
      final out = TabLifecycleEngine.drop(tabs,
          tabId: TabId('b'), drop: const TabDrop.toEnd())!;
      expect(ids(out), ['a', 'c', 'b']);
      expect(out.last.parentId, isNull);
    });

    test('a subtree that is not contiguous in the list is still passed', () {
      final tabs = [tab(TabId('a')), tab(TabId('c')), tab(TabId('b'), parent: TabId('a'))];
      final out =
          TabLifecycleEngine.reparent(tabs, tabId: TabId('c'), newParentId: TabId('a'))!;
      expect(ids(out), ['a', 'b', 'c']);
      expect(TabLifecycleEngine.treeOrder(out).map((r) => r.tab.id),
          ['a', 'b', 'c']);
    });

    test('hosts, urls and the active tab are left alone', () {
      final hosted = SiteTab(id: TabId('h'), url: 'https://duckduckgo.com/?q=x',
          hostSiteId: SiteId('ddg'));
      final tabs = [tab(TabId('a')), hosted];
      final normalized = TabLifecycleEngine.normalize(tabs,
          activeTabId: TabId('h'), fallbackUrl: 'https://x');
      final out = TabLifecycleEngine.reparent(normalized.tabs,
          tabId: TabId('h'), newParentId: TabId('a'))!;
      final moved = out.firstWhere((t) => t.id == 'h');
      expect(moved.hostSiteId, 'ddg');
      expect(moved.url, 'https://duckduckgo.com/?q=x');
      expect(identical(moved, hosted), isTrue);
    });
  });

  group('closeTab (TAB-007)', () {
    test('children move up to the closed tab\'s parent', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'), parent: TabId('b'))];
      final r =
          TabLifecycleEngine.closeTab(tabs, activeTabId: TabId('a'), closeId: TabId('b'));
      expect(ids(r.tabs), ['a', 'c']);
      expect(r.tabs.last.parentId, 'a');
      expect(r.closedIds, ['b']);
    });

    test('closing a parked tab leaves the active one bound', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'))];
      final r =
          TabLifecycleEngine.closeTab(tabs, activeTabId: TabId('a'), closeId: TabId('b'));
      expect(r.nextActiveId, 'a');
      expect(r.activeChanged, isFalse);
    });

    test('closing the active child hands over to its parent', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a'))];
      final r =
          TabLifecycleEngine.closeTab(tabs, activeTabId: TabId('b'), closeId: TabId('b'));
      expect(r.nextActiveId, 'a');
      expect(r.activeChanged, isTrue);
    });

    test('closing the active root picks the most recently active survivor',
        () {
      final tabs = [
        tab(TabId('a'), activeAt: 3000),
        tab(TabId('b'), activeAt: 1000),
        tab(TabId('c'), activeAt: 2000),
      ];
      final r =
          TabLifecycleEngine.closeTab(tabs, activeTabId: TabId('a'), closeId: TabId('a'));
      expect(r.nextActiveId, 'c');
    });

    test('closing the only tab reports an empty list for the caller to seed',
        () {
      final r = TabLifecycleEngine.closeTab([tab(TabId('a'))],
          activeTabId: TabId('a'), closeId: TabId('a'));
      expect(r.tabs, isEmpty);
      expect(r.nextActiveId, isNull);
      expect(r.activeChanged, isTrue);
    });

    test('closing a tab that is not there changes nothing', () {
      final tabs = [tab(TabId('a'))];
      final r =
          TabLifecycleEngine.closeTab(tabs, activeTabId: TabId('a'), closeId: TabId('ghost'));
      expect(ids(r.tabs), ['a']);
      expect(r.closedIds, isEmpty);
      expect(r.activeChanged, isFalse);
    });
  });

  group('closeSubtree', () {
    test('removes the tab and everything under it', () {
      final tabs = [
        tab(TabId('a')),
        tab(TabId('b'), parent: TabId('a')),
        tab(TabId('c'), parent: TabId('b')),
        tab(TabId('d')),
      ];
      final r =
          TabLifecycleEngine.closeSubtree(tabs, activeTabId: TabId('d'), closeId: TabId('b'));
      expect(ids(r.tabs), ['a', 'd']);
      expect(r.closedIds.toSet(), {'b', 'c'});
    });

    test('closing the subtree holding the active tab re-binds', () {
      final tabs = [tab(TabId('a')), tab(TabId('b'), parent: TabId('a')), tab(TabId('c'), parent: TabId('b'))];
      final r =
          TabLifecycleEngine.closeSubtree(tabs, activeTabId: TabId('c'), closeId: TabId('b'));
      expect(ids(r.tabs), ['a']);
      expect(r.nextActiveId, 'a');
      expect(r.activeChanged, isTrue);
    });
  });

  group('backAtHistoryStart (TAB-007)', () {
    test('a root tab keeps the NAV-001 no-op', () {
      expect(
        TabLifecycleEngine.backAtHistoryStart([tab(TabId('a'))], activeTabId: TabId('a')),
        TabBackAction.ignore,
      );
    });

    test('a child tab closes and hands back to its parent', () {
      expect(
        TabLifecycleEngine.backAtHistoryStart(
            [tab(TabId('a')), tab(TabId('b'), parent: TabId('a'))], activeTabId: TabId('b')),
        TabBackAction.closeAndActivateParent,
      );
    });

    test('a child whose parent is gone is treated as a root', () {
      expect(
        TabLifecycleEngine.backAtHistoryStart([tab(TabId('b'), parent: TabId('a'))],
            activeTabId: TabId('b')),
        TabBackAction.ignore,
      );
    });
  });

  group('descendants', () {
    test('walks the whole subtree', () {
      final tabs = [
        tab(TabId('a')),
        tab(TabId('b'), parent: TabId('a')),
        tab(TabId('c'), parent: TabId('b')),
        tab(TabId('d'), parent: TabId('a')),
        tab(TabId('e')),
      ];
      expect(
        TabLifecycleEngine.descendants(tabs, id: TabId('a')).map((t) => t.id).toSet(),
        {'b', 'c', 'd'},
      );
      expect(TabLifecycleEngine.descendants(tabs, id: TabId('e')), isEmpty);
    });
  });

  group('home landing (TAB-014)', () {
    const home = 'https://bank.test/';

    test('the home page matches up to scheme upgrade, case, slash, fragment',
        () {
      for (final url in [
        'https://bank.test/',
        'https://bank.test',
        'http://bank.test/',
        'https://BANK.test/#top',
      ]) {
        expect(TabLifecycleEngine.isHomeUrl(url, initUrl: home), isTrue,
            reason: url);
      }
      for (final url in [
        'https://bank.test/account',
        'https://bank.test/?next=1',
        'https://other.test/',
        'https://bank.test:8443/',
        'ftp://bank.test/',
      ]) {
        expect(TabLifecycleEngine.isHomeUrl(url, initUrl: home), isFalse,
            reason: url);
      }
    });

    test('a site already at home stays on its tab', () {
      final tabs = [tab(TabId('a'), url: 'https://bank.test')];
      expect(
          TabLifecycleEngine.homeLanding(tabs, activeTabId: TabId('a'), initUrl: home),
          isNull);
    });

    test('a site away from home gets a new root tab there, keeping its own',
        () {
      final tabs = [tab(TabId('a'), url: 'https://bank.test/account/1')];
      final r = TabLifecycleEngine.homeLanding(tabs,
          activeTabId: TabId('a'), initUrl: home)!;
      expect(r.tabs, hasLength(2));
      expect(r.tabs.first.url, 'https://bank.test/account/1');
      final landed = r.tabs.firstWhere((t) => t.id == r.activeTabId);
      expect(landed.url, home);
      expect(landed.parentId, isNull);
      expect(landed.id, isNot('a'));
    });

    test('a parked tab already at home is reused rather than duplicated', () {
      final tabs = [
        tab(TabId('old'), url: home, activeAt: 1),
        tab(TabId('a'), url: 'https://bank.test/account/1', activeAt: 3),
        tab(TabId('recent'), url: 'https://bank.test/', activeAt: 2),
      ];
      final r = TabLifecycleEngine.homeLanding(tabs,
          activeTabId: TabId('a'), initUrl: home)!;
      expect(ids(r.tabs), ['old', 'a', 'recent']);
      expect(r.activeTabId, 'recent');
    });
  });
}
