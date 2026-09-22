import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';

SiteTab tab(String id, {String? parent, String? url, int? activeAt}) => SiteTab(
      id: id,
      url: url ?? 'https://example.org/$id',
      parentId: parent,
      lastActiveAt: activeAt == null
          ? DateTime(2026, 1, 1)
          : DateTime.fromMillisecondsSinceEpoch(activeAt),
    );

List<String> ids(List<SiteTab> tabs) => tabs.map((t) => t.id).toList();

void main() {
  group('normalize (TAB-001)', () {
    test('an empty list becomes one primary tab at the fallback url', () {
      final r = TabLifecycleEngine.normalize(null, null, 'https://site.test/');
      expect(r.tabs, hasLength(1));
      expect(r.tabs.single.id, kPrimaryTabId);
      expect(r.tabs.single.url, 'https://site.test/');
      expect(r.activeTabId, kPrimaryTabId);
    });

    test('duplicate ids collapse to the first occurrence', () {
      final r = TabLifecycleEngine.normalize(
          [tab('a'), tab('a', url: 'https://other.test/'), tab('b')],
          'b',
          'https://site.test/');
      expect(ids(r.tabs), ['a', 'b']);
      expect(r.tabs.first.url, 'https://example.org/a');
    });

    test('a parent that is not in the list is dropped, the tab is kept', () {
      final r = TabLifecycleEngine.normalize(
          [tab('a', parent: 'ghost')], 'a', 'https://site.test/');
      expect(ids(r.tabs), ['a']);
      expect(r.tabs.single.parentId, isNull);
    });

    test('a parent cycle is broken without losing a tab', () {
      final r = TabLifecycleEngine.normalize(
          [tab('a', parent: 'b'), tab('b', parent: 'a')],
          'a',
          'https://site.test/');
      expect(ids(r.tabs), ['a', 'b']);
      // Whichever way the cycle is cut, walking parents must terminate.
      expect(TabLifecycleEngine.treeOrder(r.tabs), hasLength(2));
    });

    test('a tab that is its own parent is rooted', () {
      final r = TabLifecycleEngine.normalize(
          [tab('a', parent: 'a')], 'a', 'https://site.test/');
      expect(r.tabs.single.parentId, isNull);
    });

    test('an activeTabId naming nothing falls back to the first tab', () {
      final r = TabLifecycleEngine.normalize(
          [tab('a'), tab('b')], 'ghost', 'https://site.test/');
      expect(r.activeTabId, 'a');
    });
  });

  group('treeOrder (TAB-008)', () {
    test('children follow their parent, indented by depth', () {
      final tabs = [
        tab('a'),
        tab('b', parent: 'a'),
        tab('c', parent: 'b'),
        tab('d'),
      ];
      final rows = TabLifecycleEngine.treeOrder(tabs);
      expect(rows.map((r) => r.tab.id).toList(), ['a', 'b', 'c', 'd']);
      expect(rows.map((r) => r.depth).toList(), [0, 1, 2, 0]);
    });

    test('childCount counts direct children only', () {
      final rows = TabLifecycleEngine.treeOrder([
        tab('a'),
        tab('b', parent: 'a'),
        tab('c', parent: 'a'),
        tab('d', parent: 'b'),
      ]);
      expect(rows.firstWhere((r) => r.tab.id == 'a').childCount, 2);
      expect(rows.firstWhere((r) => r.tab.id == 'b').childCount, 1);
    });

    test('every tab appears exactly once', () {
      final tabs = [
        tab('a'),
        tab('b', parent: 'a'),
        tab('c', parent: 'ghost'),
      ];
      final rows = TabLifecycleEngine.treeOrder(tabs);
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.tab.id).toSet(), {'a', 'b', 'c'});
    });
  });

  group('insertChild', () {
    test('a child lands directly after its parent', () {
      final tabs = [tab('a'), tab('b')];
      final out =
          TabLifecycleEngine.insertChild(tabs, tab('c', parent: 'a'));
      expect(ids(out), ['a', 'c', 'b']);
    });

    test('a second child lands after the first subtree, not inside it', () {
      var tabs = [tab('a'), tab('b')];
      tabs = TabLifecycleEngine.insertChild(tabs, tab('c', parent: 'a'));
      tabs = TabLifecycleEngine.insertChild(tabs, tab('d', parent: 'c'));
      tabs = TabLifecycleEngine.insertChild(tabs, tab('e', parent: 'a'));
      expect(ids(tabs), ['a', 'c', 'd', 'e', 'b']);
      expect(
        TabLifecycleEngine.treeOrder(tabs).map((r) => r.depth).toList(),
        [0, 1, 2, 1, 0],
      );
    });

    test('a root tab goes to the end', () {
      final out = TabLifecycleEngine.insertChild([tab('a')], tab('z'));
      expect(ids(out), ['a', 'z']);
    });
  });

  group('closeTab (TAB-007)', () {
    test('children move up to the closed tab\'s parent', () {
      final tabs = [tab('a'), tab('b', parent: 'a'), tab('c', parent: 'b')];
      final r = TabLifecycleEngine.closeTab(tabs, 'a', 'b');
      expect(ids(r.tabs), ['a', 'c']);
      expect(r.tabs.last.parentId, 'a');
      expect(r.closedIds, ['b']);
    });

    test('closing a parked tab leaves the active one bound', () {
      final tabs = [tab('a'), tab('b')];
      final r = TabLifecycleEngine.closeTab(tabs, 'a', 'b');
      expect(r.nextActiveId, 'a');
      expect(r.activeChanged, isFalse);
    });

    test('closing the active child hands over to its parent', () {
      final tabs = [tab('a'), tab('b', parent: 'a')];
      final r = TabLifecycleEngine.closeTab(tabs, 'b', 'b');
      expect(r.nextActiveId, 'a');
      expect(r.activeChanged, isTrue);
    });

    test('closing the active root picks the most recently active survivor',
        () {
      final tabs = [
        tab('a', activeAt: 3000),
        tab('b', activeAt: 1000),
        tab('c', activeAt: 2000),
      ];
      final r = TabLifecycleEngine.closeTab(tabs, 'a', 'a');
      expect(r.nextActiveId, 'c');
    });

    test('closing the only tab reports an empty list for the caller to seed',
        () {
      final r = TabLifecycleEngine.closeTab([tab('a')], 'a', 'a');
      expect(r.tabs, isEmpty);
      expect(r.nextActiveId, isNull);
      expect(r.activeChanged, isTrue);
    });

    test('closing a tab that is not there changes nothing', () {
      final tabs = [tab('a')];
      final r = TabLifecycleEngine.closeTab(tabs, 'a', 'ghost');
      expect(ids(r.tabs), ['a']);
      expect(r.closedIds, isEmpty);
      expect(r.activeChanged, isFalse);
    });
  });

  group('closeSubtree', () {
    test('removes the tab and everything under it', () {
      final tabs = [
        tab('a'),
        tab('b', parent: 'a'),
        tab('c', parent: 'b'),
        tab('d'),
      ];
      final r = TabLifecycleEngine.closeSubtree(tabs, 'd', 'b');
      expect(ids(r.tabs), ['a', 'd']);
      expect(r.closedIds.toSet(), {'b', 'c'});
    });

    test('closing the subtree holding the active tab re-binds', () {
      final tabs = [tab('a'), tab('b', parent: 'a'), tab('c', parent: 'b')];
      final r = TabLifecycleEngine.closeSubtree(tabs, 'c', 'b');
      expect(ids(r.tabs), ['a']);
      expect(r.nextActiveId, 'a');
      expect(r.activeChanged, isTrue);
    });
  });

  group('closeParked', () {
    test('keeps the active tab and drops the rest', () {
      final tabs = [tab('a'), tab('b', parent: 'a'), tab('c')];
      final r = TabLifecycleEngine.closeParked(tabs, 'b');
      expect(ids(r.tabs), ['b']);
      expect(r.tabs.single.parentId, isNull);
      expect(r.nextActiveId, 'b');
      expect(r.activeChanged, isFalse);
    });
  });

  group('backAtHistoryStart (TAB-007)', () {
    test('a root tab keeps the NAV-001 no-op', () {
      expect(
        TabLifecycleEngine.backAtHistoryStart([tab('a')], 'a'),
        TabBackAction.ignore,
      );
    });

    test('a child tab closes and hands back to its parent', () {
      expect(
        TabLifecycleEngine.backAtHistoryStart(
            [tab('a'), tab('b', parent: 'a')], 'b'),
        TabBackAction.closeAndActivateParent,
      );
    });

    test('a child whose parent is gone is treated as a root', () {
      expect(
        TabLifecycleEngine.backAtHistoryStart([tab('b', parent: 'a')], 'b'),
        TabBackAction.ignore,
      );
    });
  });

  group('descendants', () {
    test('walks the whole subtree', () {
      final tabs = [
        tab('a'),
        tab('b', parent: 'a'),
        tab('c', parent: 'b'),
        tab('d', parent: 'a'),
        tab('e'),
      ];
      expect(
        TabLifecycleEngine.descendants(tabs, 'a').map((t) => t.id).toSet(),
        {'b', 'c', 'd'},
      );
      expect(TabLifecycleEngine.descendants(tabs, 'e'), isEmpty);
    });
  });
}
