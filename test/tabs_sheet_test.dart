import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tabs_sheet.dart';

/// A site with [urls] as tabs. The first is the active one; every later tab is
/// a child of the one before it, so the fixture is a chain three deep.
WebViewModel siteWithChain(String name, List<String> urls) {
  final m = WebViewModel(initUrl: urls.first, name: name);
  var parent = m.activeTabId;
  for (final url in urls.skip(1)) {
    final t = SiteTab(id: 'tab${m.tabs.length}', url: url, parentId: parent);
    m.tabs = [...m.tabs, t];
    parent = t.id;
  }
  return m;
}

Future<void> pumpSheet(
  WidgetTester tester,
  List<TabsSheetSite> sites, {
  void Function(int, String)? onOpenTab,
  void Function(int)? onNewTab,
  VoidCallback? onWebSearch,
  void Function(int, String)? onCloseTab,
  void Function(int, String)? onCloseSubtree,
  bool Function(int, String, TabDrop)? onMoveTab,
  Locale? locale,
  double width = 400,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    home: Scaffold(
      key: UniqueKey(),
      body: TabsSheet(
        sites: sites,
        currentIndex: 0,
        onOpenTab: onOpenTab ?? (_, _) {},
        onNewTab: onNewTab ?? (_) {},
        onWebSearch: onWebSearch,
        onCloseTab: onCloseTab ?? (_, _) {},
        onCloseSubtree: onCloseSubtree ?? (_, _) {},
        onMoveTab: onMoveTab,
      ),
    ),
  ));
  await tester.pump();
}

/// How strongly the row showing [text] is drawn: 1 for a tab that holds a
/// webview, faded for a stored one (TAB-011).
double strengthOf(WidgetTester tester, String text) => tester
    .widget<Opacity>(find
        .ancestor(of: find.text(text).first, matching: find.byType(Opacity))
        .first)
    .opacity;

/// Whether the row showing [text] carries the selected-row highlight that
/// marks the tab on screen.
bool isHighlighted(String text) => find
    .ancestor(of: find.text(text).first, matching: find.byType(Ink))
    .evaluate()
    .isNotEmpty;

/// A site with [urls] as root tabs, the first one active.
WebViewModel siteWithRoots(String name, List<String> urls) {
  final m = WebViewModel(initUrl: urls.first, name: name);
  for (final url in urls.skip(1)) {
    m.tabs = [...m.tabs, SiteTab(id: 'tab${m.tabs.length}', url: url)];
  }
  return m;
}

/// Long-press the row showing [from] and drop it at [fraction] of the height
/// of the row showing [to], or past the last row when [to] is null.
Future<void> dragRow(WidgetTester tester, String from, String? to,
    {double fraction = 0.5}) async {
  final start = tester.getCenter(find.text(from));
  final Offset end;
  if (to == null) {
    final last = tester.getRect(find.byType(InkWell).last);
    end = Offset(last.center.dx, last.bottom + Spacing.sm);
  } else {
    final row = tester.getRect(find
        .ancestor(of: find.text(to), matching: find.byType(InkWell))
        .first);
    end = Offset(row.center.dx, row.top + row.height * fraction);
  }
  final gesture = await tester.startGesture(start);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await gesture.moveTo(end - const Offset(0, 1));
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Row texts top to bottom.
List<String> rowOrder(WidgetTester tester, List<String> texts) {
  final ys = {for (final t in texts) t: tester.getCenter(find.text(t)).dy};
  return [...texts]..sort((a, b) => ys[a]!.compareTo(ys[b]!));
}

void main() {
  group('TAB-015 — drag to reorder and nest', () {
    const a = 'https://github.com/a';
    const b = 'https://github.com/b';
    const c = 'https://github.com/c';

    Future<(WebViewModel, List<(String, TabDrop)>)> pumpDraggable(
        WidgetTester tester) async {
      final m = siteWithRoots('GitHub', [a, b, c]);
      final drops = <(String, TabDrop)>[];
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: m, isCurrent: true, isLoaded: true)],
        onMoveTab: (i, id, drop) {
          drops.add((id, drop));
          final moved = TabLifecycleEngine.drop(m.tabs, id, drop);
          if (moved == null) return false;
          m.tabs = moved;
          return true;
        },
      );
      return (m, drops);
    }

    String idOf(WebViewModel m, String url) =>
        m.tabs.firstWhere((t) => t.url == url).id;

    testWidgets('the middle of a row nests the tab under it', (tester) async {
      final (m, drops) = await pumpDraggable(tester);
      await dragRow(tester, c, a);
      expect(drops.single.$2.zone, TabDropZone.into);
      expect(m.tabs.firstWhere((t) => t.url == c).parentId, idOf(m, a));
      expect(rowOrder(tester, [a, b, c]), [a, c, b]);
      expect(tester.getTopLeft(find.text(c)).dx,
          greaterThan(tester.getTopLeft(find.text(a)).dx),
          reason: 'the nested tab is indented');
    });

    testWidgets('the top of a row puts the tab before it', (tester) async {
      final (m, drops) = await pumpDraggable(tester);
      await dragRow(tester, c, a, fraction: 0.1);
      expect(drops.single.$2.zone, TabDropZone.before);
      expect(rowOrder(tester, [a, b, c]), [c, a, b]);
      expect(m.tabs.every((t) => t.parentId == null), isTrue);
    });

    testWidgets('the bottom of a row puts the tab after it', (tester) async {
      final (_, drops) = await pumpDraggable(tester);
      await dragRow(tester, a, b, fraction: 0.9);
      expect(drops.single.$2.zone, TabDropZone.after);
      expect(rowOrder(tester, [a, b, c]), [b, a, c]);
    });

    testWidgets('past the last row the tab becomes the last root',
        (tester) async {
      final (_, drops) = await pumpDraggable(tester);
      await dragRow(tester, a, null);
      expect(drops.single.$2.targetId, isNull);
      expect(rowOrder(tester, [a, b, c]), [b, c, a]);
    });

    testWidgets('a tab is not dropped into its own subtree', (tester) async {
      final m = siteWithChain('GitHub', [a, b, c]);
      final drops = <TabDrop>[];
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: m, isCurrent: true, isLoaded: true)],
        onMoveTab: (i, id, drop) {
          drops.add(drop);
          return false;
        },
      );
      await dragRow(tester, a, c);
      expect(drops, isEmpty);
    });

    testWidgets('without a move handler a long press drags nothing',
        (tester) async {
      final m = siteWithRoots('GitHub', [a, b]);
      await pumpSheet(tester,
          [TabsSheetSite(index: 0, model: m, isCurrent: true, isLoaded: true)]);
      expect(find.byWidgetPredicate((w) => w is LongPressDraggable),
          findsNothing);
      expect(find.byWidgetPredicate((w) => w is DragTarget), findsNothing);
    });
  });

  group('TAB-008 — the tab list', () {
    testWidgets('lists every tab of the site, with the open one selected',
        (tester) async {
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
        'https://github.com/pull/601',
      ]);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true),
      ]);

      expect(find.textContaining('github.com'), findsWidgets);
      expect(find.text('GitHub · 3 tabs'), findsOneWidget);
      // Exactly one row is the loaded one: the active tab of the site on
      // screen. Every other tab is stored, not running.
      expect(strengthOf(tester, 'https://github.com/'), 1);
      expect(isHighlighted('https://github.com/'), isTrue);
      for (final stored in [
        'https://github.com/pulls',
        'https://github.com/pull/601',
      ]) {
        expect(strengthOf(tester, stored), lessThan(1));
        expect(isHighlighted(stored), isFalse);
      }
      expect(find.text('open'), findsNothing);
    });

    testWidgets('a site on one tab says so in the singular', (tester) async {
      final site = siteWithChain('Mastodon', ['https://mastodon.social/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true),
      ]);
      expect(find.text('Mastodon · 1 tab'), findsOneWidget);
    });

    testWidgets('collapsing a tab hides the tabs opened from it',
        (tester) async {
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
        'https://github.com/pull/601',
      ]);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true),
      ]);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pump();

      // The whole subtree goes, not just the direct child.
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.text('2 tabs hidden'), findsOneWidget);
    });

    testWidgets('New tab reports the site it belongs to', (tester) async {
      int? opened;
      final site = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 7, model: site, isCurrent: true, isLoaded: true)],
        onNewTab: (i) => opened = i,
      );
      await tester.tap(find.text('New tab'));
      await tester.pump();
      expect(opened, 7);
    });

    testWidgets('Web search sits beside New tab (LIR-029)', (tester) async {
      var searched = 0;
      final site = siteWithChain('GitHub', ['https://github.com/']);
      final sites = [
        TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true),
      ];
      await pumpSheet(tester, sites);
      expect(find.byIcon(Icons.travel_explore), findsNothing);
      await pumpSheet(tester, sites, onWebSearch: () => searched++);
      await tester.tap(find.byIcon(Icons.travel_explore));
      await tester.pump();
      expect(searched, 1);
    });

    testWidgets('both labels show where they fit', (tester) async {
      final site = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true)],
        onWebSearch: () {},
        width: 600,
      );
      expect(find.text('Web search'), findsOneWidget);
      expect(find.text('New tab'), findsOneWidget);
    });

    testWidgets('the header fits a phone in every locale', (tester) async {
      final site = siteWithChain('GitHub', ['https://github.com/']);
      const width = 360.0;
      for (final locale in AppLocalizations.supportedLocales) {
        await pumpSheet(
          tester,
          [TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true)],
          onWebSearch: () {},
          locale: locale,
          width: width,
        );
        // A locale without Material strings warns; only an overflow fails.
        final error = tester.takeException();
        expect('$error', isNot(contains('overflowed')), reason: '$locale');
        for (final icon in [Icons.travel_explore, Icons.add]) {
          final rect = tester.getRect(find.byIcon(icon));
          expect(rect.left >= 0 && rect.right <= width, isTrue,
              reason: '$locale: $icon at $rect');
        }
        final title = tester.getRect(find.textContaining('GitHub'));
        expect(title.width, greaterThan(40), reason: '$locale title');
      }
    });

    testWidgets('closing a row reports that tab', (tester) async {
      String? closed;
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
      ]);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true)],
        onCloseTab: (_, id) => closed = id,
      );
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(closed, site.tabs.last.id);
    });

    testWidgets('a tab with children offers closing the subtree',
        (tester) async {
      String? closed;
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
      ]);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true)],
        onCloseSubtree: (_, id) => closed = id,
      );
      // Only the parent row has the control: the leaf has nothing under it.
      expect(find.byIcon(Icons.layers_clear_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.layers_clear_outlined));
      await tester.pump();
      expect(closed, site.tabs.first.id);
    });

    testWidgets('the all-sites scope appears only with more than one site',
        (tester) async {
      final a = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: true),
      ]);
      expect(find.text('All sites'), findsNothing);

      final b = siteWithChain('Mastodon', ['https://mastodon.social/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: true),
        TabsSheetSite(index: 1, model: b, isCurrent: false, isLoaded: false),
      ]);
      expect(find.text('All sites'), findsOneWidget);
      expect(find.text('This site'), findsOneWidget);

      await tester.tap(find.text('All sites'));
      await tester.pump();
      // Both sites' headings are present once the scope widens.
      expect(find.text('GitHub · 1 tab'), findsWidgets);
      expect(find.text('Mastodon · 1 tab'), findsOneWidget);
    });

    testWidgets('TAB-011 — a tab is faded unless the load policy holds it',
        (tester) async {
      final a = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
      ]);
      final b = siteWithChain('Mastodon', [
        'https://mastodon.social/',
        'https://mastodon.social/@a',
      ]);
      final c = siteWithChain('Wikipedia', ['https://en.wikipedia.org/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: true),
        // Backgrounded but still resident: its active tab keeps a paused
        // webview until the policy evicts the site.
        TabsSheetSite(index: 1, model: b, isCurrent: false, isLoaded: true),
        // Unloaded by the policy: nothing of it is in memory.
        TabsSheetSite(index: 2, model: c, isCurrent: false, isLoaded: false),
      ]);
      await tester.tap(find.text('All sites'));
      await tester.pump();
      // One tab per loaded site holds a webview, never more (TAB-002), and
      // only the one on screen is selected.
      expect(strengthOf(tester, 'https://github.com/'), 1);
      expect(isHighlighted('https://github.com/'), isTrue);
      expect(strengthOf(tester, 'https://mastodon.social/'), 1);
      expect(isHighlighted('https://mastodon.social/'), isFalse);
      // Each site's other tabs, and every tab of the unloaded site, are
      // stored and faded.
      expect(strengthOf(tester, 'https://github.com/pulls'), lessThan(1));
      expect(strengthOf(tester, 'https://mastodon.social/@a'), lessThan(1));
      expect(strengthOf(tester, 'https://en.wikipedia.org/'), lessThan(1));
      // The fade has no words on screen; a screen reader gets them instead.
      expect(find.text('open'), findsNothing);
      expect(find.text('loaded'), findsNothing);
      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(find
          .ancestor(
              of: find.text('https://mastodon.social/').first,
              matching: find.byType(Semantics))
          .first);
      expect(node.value, 'loaded');
      handle.dispose();
    });

    testWidgets('the site on screen but not yet built draws its tab faded',
        (tester) async {
      final a = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: false),
      ]);
      expect(strengthOf(tester, 'https://github.com/'), lessThan(1));
      expect(isHighlighted('https://github.com/'), isFalse);
    });
  });
}
