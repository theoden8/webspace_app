import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/services/tab_return_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';
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
  List<TabsSheetSite>? Function(String, String)? onMoveSite,
  TabReturn? wayBack,
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
        onMoveSite: onMoveSite,
        wayBack: wayBack,
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

  group('TAB-016 — drag a site heading to reorder sites', () {
    const gh = 'GitHub · 1 tab';
    const md = 'Mastodon · 1 tab';
    const wp = 'Wikipedia · 1 tab';

    /// Three sites in the All sites view. The host fake reorders as the
    /// drawer does and renumbers every site, as reordering "All" does.
    Future<(List<WebViewModel>, List<(String, String)>)> pumpSites(
        WidgetTester tester,
        {bool refuse = false,
        void Function(int, String)? onOpenTab}) async {
      final models = [
        siteWithChain('GitHub', ['https://github.com/']),
        siteWithChain('Mastodon', ['https://mastodon.social/']),
        siteWithChain('Wikipedia', ['https://en.wikipedia.org/']),
      ];
      final current = models.first;
      List<TabsSheetSite> sites() => [
            for (var i = 0; i < models.length; i++)
              TabsSheetSite(
                index: i,
                model: models[i],
                isCurrent: models[i] == current,
                isLoaded: models[i] == current,
              ),
          ];
      final moves = <(String, String)>[];
      await pumpSheet(
        tester,
        sites(),
        onOpenTab: onOpenTab,
        onMoveSite: (id, onto) {
          moves.add((id, onto));
          if (refuse) return null;
          final from = models.indexWhere((m) => m.siteId == id);
          final to = models.indexWhere((m) => m.siteId == onto);
          models.insert(to, models.removeAt(from));
          return sites();
        },
      );
      await tester.tap(find.text('All sites'));
      await tester.pumpAndSettle();
      return (models, moves);
    }

    // The site on screen also names the sheet; its heading is the last match.
    Finder heading(String text) => find.text(text).last;

    List<String> headingOrder(WidgetTester tester) {
      final ys = {
        for (final t in [gh, md, wp]) t: tester.getCenter(heading(t)).dy,
      };
      return [gh, md, wp]..sort((a, b) => ys[a]!.compareTo(ys[b]!));
    }

    Future<void> dragHeading(
        WidgetTester tester, String from, String to) async {
      final gesture = await tester.startGesture(tester.getCenter(heading(from)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      final end = tester.getCenter(heading(to));
      await gesture.moveTo(end - const Offset(0, 1));
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('a site dropped on an earlier heading takes its place',
        (tester) async {
      final (models, moves) = await pumpSites(tester);
      final wikipedia = models[2].siteId;
      final github = models[0].siteId;
      await dragHeading(tester, wp, gh);
      expect(moves, [(wikipedia, github)]);
      expect([for (final m in models) m.name],
          ['Wikipedia', 'GitHub', 'Mastodon']);
      expect(headingOrder(tester), [wp, gh, md]);
    });

    testWidgets('a site dropped on a later heading takes its place',
        (tester) async {
      final (models, _) = await pumpSites(tester);
      await dragHeading(tester, gh, md);
      expect([for (final m in models) m.name],
          ['Mastodon', 'GitHub', 'Wikipedia']);
      expect(headingOrder(tester), [md, gh, wp]);
    });

    testWidgets('a refused move leaves the headings where they were',
        (tester) async {
      final (_, moves) = await pumpSites(tester, refuse: true);
      await dragHeading(tester, wp, gh);
      expect(moves, hasLength(1));
      expect(headingOrder(tester), [gh, md, wp]);
    });

    testWidgets('tabs open by the numbering the host hands back',
        (tester) async {
      final opened = <int>[];
      await pumpSites(tester, onOpenTab: (i, _) => opened.add(i));
      await dragHeading(tester, wp, gh);
      await tester.tap(find.text('https://en.wikipedia.org/'));
      await tester.pumpAndSettle();
      expect(opened, [0]);
    });

    testWidgets('This site follows the site on screen to its new number',
        (tester) async {
      final opened = <int>[];
      final (models, _) =
          await pumpSites(tester, onOpenTab: (i, _) => opened.add(i));
      await dragHeading(tester, wp, gh);
      expect(models[1].name, 'GitHub');
      await tester.tap(find.text('This site'));
      await tester.pumpAndSettle();
      expect(find.text('https://en.wikipedia.org/'), findsNothing);
      await tester.tap(find.text('https://github.com/'));
      await tester.pumpAndSettle();
      expect(opened, [1]);
    });

    testWidgets('without a host reorder the headings are not draggable',
        (tester) async {
      final a = siteWithChain('GitHub', ['https://github.com/']);
      final b = siteWithChain('Mastodon', ['https://mastodon.social/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: true),
        TabsSheetSite(index: 1, model: b, isCurrent: false, isLoaded: false),
      ]);
      await tester.tap(find.text('All sites'));
      await tester.pumpAndSettle();
      expect(
          find.ancestor(
              of: find.text(md),
              matching:
                  find.byWidgetPredicate((w) => w is LongPressDraggable)),
          findsNothing);
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

  group('TAB-017, TAB-018 — subtrees from other sites, container marks', () {
    const ddgHome = 'https://duckduckgo.com/';
    const hosted = 'https://duckduckgo.com/?q=hosted';
    const below = 'https://github.com/below-hosted';
    const foreign = 'https://duckduckgo.com/?q=foreign';
    const ddgChild = 'https://duckduckgo.com/?q=own';

    late WebViewModel gh;
    late WebViewModel ddg;

    setUp(() {
      // GitHub's tree: its home, a tab a link opened as DuckDuckGo with a
      // GitHub page opened below it, and one a link opened while GitHub's
      // routing was off, which runs as GitHub in DuckDuckGo's domain.
      gh = WebViewModel(
        siteId: 'gh',
        initUrl: 'https://github.com/',
        name: 'GitHub',
        containerColor: 0,
        tabs: [
          SiteTab.primary(url: 'https://github.com/'),
          SiteTab(
              id: 'h',
              url: hosted,
              parentId: kPrimaryTabId,
              hostSiteId: 'ddg',
              openerSiteId: 'gh',
              homeUrl: hosted),
          SiteTab(id: 'h1', url: below, parentId: 'h'),
          SiteTab(
              id: 'f',
              url: foreign,
              parentId: kPrimaryTabId,
              openerSiteId: 'gh',
              homeUrl: foreign),
        ],
      );
      ddg = WebViewModel(
        siteId: 'ddg',
        initUrl: ddgHome,
        name: 'DuckDuckGo',
        containerColor: 1,
        tabs: [
          SiteTab.primary(url: ddgHome),
          SiteTab(id: 'own', url: ddgChild, parentId: kPrimaryTabId),
        ],
      );
      final byId = {'gh': gh, 'ddg': ddg};
      WebViewModel.siteLookup = (id) => byId[id];
    });
    tearDown(() => WebViewModel.siteLookup = null);

    /// DuckDuckGo on screen, GitHub after it.
    List<TabsSheetSite> sites() => [
          TabsSheetSite(index: 1, model: ddg, isCurrent: true, isLoaded: true),
          TabsSheetSite(index: 0, model: gh, isCurrent: false, isLoaded: false),
        ];

    WebViewModel markedAs(WidgetTester tester, String text) => tester
        .widget<ContainerMark>(find.descendant(
          of: find
              .ancestor(of: find.text(text).first, matching: find.byType(InkWell))
              .first,
          matching: find.byType(ContainerMark),
        ))
        .site;

    bool draggable(String text) => find
        .ancestor(
          of: find.text(text).first,
          matching: find.byWidgetPredicate((w) => w is LongPressDraggable),
        )
        .evaluate()
        .isNotEmpty;

    testWidgets('This site lists the other site\'s tree around what runs as it',
        (tester) async {
      await pumpSheet(tester, sites(), onMoveTab: (_, _, _) => true);
      expect(find.text('In GitHub'), findsOneWidget);
      expect(find.text(hosted), findsOneWidget);
      expect(find.text(below), findsOneWidget,
          reason: 'the subtree comes whole, whatever its tabs run as');
      expect(find.text('https://github.com/'), findsOneWidget,
          reason: 'the tabs above it are the way to it');
      expect(find.text(foreign), findsNothing,
          reason: 'a branch with nothing run as DuckDuckGo is folded');
      expect(find.text('1 more GitHub tab'), findsOneWidget);
      expect(
          rowOrder(tester, [ddgHome, ddgChild, 'https://github.com/', hosted, below]),
          [ddgHome, ddgChild, 'https://github.com/', hosted, below]);
      expect(
        tester.getTopLeft(find.text('In GitHub')).dy,
        greaterThan(tester.getTopLeft(find.text(ddgChild)).dy),
        reason: 'the site\'s own tree comes first',
      );
    });

    testWidgets('the folded part of a tree opens on a tap', (tester) async {
      await pumpSheet(tester, sites());
      await tester.tap(find.text('1 more GitHub tab'));
      await tester.pump();
      expect(find.text(foreign), findsOneWidget);
      expect(find.text('1 more GitHub tab'), findsNothing);
    });

    testWidgets('on a tab GitHub runs as DuckDuckGo, the list is DuckDuckGo\'s',
        (tester) async {
      gh.activeTabId = 'h';
      final newTabs = <int>[];
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: gh, isCurrent: true, isLoaded: true),
        TabsSheetSite(index: 1, model: ddg, isCurrent: false, isLoaded: true),
      ], onNewTab: newTabs.add);
      expect(find.text('DuckDuckGo · 2 tabs'), findsOneWidget);
      expect(
          rowOrder(tester, [ddgHome, ddgChild, 'https://github.com/', hosted]),
          [ddgHome, ddgChild, 'https://github.com/', hosted],
          reason: 'the same list as on DuckDuckGo, so nothing moves on a jump');
      expect(isHighlighted(hosted), isTrue,
          reason: 'the highlight is the tab on screen, in whichever tree');
      expect(isHighlighted(ddgHome), isFalse);
      await tester.tap(find.text('New tab'));
      await tester.pump();
      expect(newTabs, [1], reason: 'a new tab of the site the list is for');
    });

    testWidgets('where the user was is marked and its tree listed',
        (tester) async {
      final wiki = WebViewModel(
        siteId: 'wiki',
        initUrl: 'https://wikipedia.org/',
        name: 'Wikipedia',
        tabs: [
          SiteTab.primary(url: 'https://wikipedia.org/'),
          SiteTab(id: 'w', url: 'https://wikipedia.org/w', parentId: kPrimaryTabId),
          SiteTab(id: 'x', url: 'https://wikipedia.org/x', parentId: kPrimaryTabId),
        ],
      );
      WebViewModel.siteLookup = (id) => {'gh': gh, 'ddg': ddg, 'wiki': wiki}[id];
      await pumpSheet(tester, [
        ...sites(),
        TabsSheetSite(index: 2, model: wiki, isCurrent: false, isLoaded: true),
      ], wayBack: const TabReturn(
          fromSiteId: 'wiki', fromTabId: 'w', toSiteId: 'ddg', toTabId: kPrimaryTabId));
      expect(find.text('In Wikipedia'), findsOneWidget,
          reason: 'nothing there runs as DuckDuckGo, but the way back is there');
      expect(find.text('wikipedia.org · where you were'), findsOneWidget);
      expect(find.text('https://wikipedia.org/x'), findsNothing);
      expect(find.text('1 more Wikipedia tab'), findsOneWidget);
    });

    testWidgets('a site the webspace hides still lists what runs as this one',
        (tester) async {
      await pumpSheet(tester, [
        TabsSheetSite(index: 1, model: ddg, isCurrent: true, isLoaded: true),
        TabsSheetSite(
            index: 0,
            model: gh,
            isCurrent: false,
            isLoaded: false,
            inView: false),
      ]);
      expect(find.text('In GitHub'), findsOneWidget);
      expect(find.text(hosted), findsOneWidget);
      expect(find.text('All sites'), findsNothing,
          reason: 'one site of the webspace has tabs, so there is no scope');
    });

    testWidgets('All sites heads only the sites the webspace shows',
        (tester) async {
      final other = WebViewModel(
          siteId: 'wiki',
          initUrl: 'https://wikipedia.org/',
          name: 'Wikipedia');
      await pumpSheet(tester, [
        TabsSheetSite(index: 1, model: ddg, isCurrent: true, isLoaded: true),
        TabsSheetSite(index: 2, model: other, isCurrent: false, isLoaded: false),
        TabsSheetSite(
            index: 0,
            model: gh,
            isCurrent: false,
            isLoaded: false,
            inView: false),
      ]);
      await tester.tap(find.text('All sites'));
      await tester.pumpAndSettle();
      expect(find.textContaining('DuckDuckGo'), findsWidgets);
      expect(find.textContaining('Wikipedia'), findsWidgets);
      expect(find.textContaining('GitHub'), findsNothing);
    });

    testWidgets('a site nothing elsewhere runs as gets no extra heading',
        (tester) async {
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: gh, isCurrent: true, isLoaded: true),
        TabsSheetSite(index: 1, model: ddg, isCurrent: false, isLoaded: false),
      ]);
      expect(find.textContaining('In '), findsNothing);
    });

    testWidgets('a tap opens the tab in the site whose tree holds it',
        (tester) async {
      final opened = <(int, String)>[];
      await pumpSheet(tester, sites(), onOpenTab: (i, id) => opened.add((i, id)));
      await tester.tap(find.text(hosted));
      await tester.pump();
      expect(opened, [(0, 'h')]);
    });

    testWidgets('rows from another site\'s tree are not dragged from here',
        (tester) async {
      final moves = <String>[];
      await pumpSheet(tester, sites(), onMoveTab: (_, id, _) {
        moves.add(id);
        return true;
      });
      expect(draggable(ddgChild), isTrue);
      expect(draggable(hosted), isFalse);
      expect(draggable(below), isFalse);
      await dragRow(tester, hosted, ddgHome);
      expect(moves, isEmpty);
    });

    testWidgets('each row is marked with the container it runs in',
        (tester) async {
      await pumpSheet(tester, sites());
      expect(markedAs(tester, ddgHome), same(ddg));
      expect(markedAs(tester, hosted), same(ddg));
      expect(markedAs(tester, below), same(gh));

      await tester.tap(find.text('All sites'));
      await tester.pump();
      expect(markedAs(tester, foreign), same(gh),
          reason: 'routing off: the tab runs in its opener\'s container');
      expect(find.text('as GitHub · duckduckgo.com'), findsOneWidget,
          reason: 'a foreign row names the site it runs as');
      expect(find.text('as DuckDuckGo · duckduckgo.com'), findsWidgets);
    });

    testWidgets('a mark draws its site\'s colour for the theme brightness',
        (tester) async {
      await pumpSheet(tester, sites());
      Color colourOf(String text) {
        final mark = find.descendant(
          of: find.ancestor(of: find.text(text).first, matching: find.byType(InkWell)).first,
          matching: find.byType(ContainerMark),
        );
        final box = tester.widget<Container>(
            find.descendant(of: mark, matching: find.byType(Container)));
        return (box.decoration! as BoxDecoration).color!;
      }

      expect(colourOf(hosted), ContainerColors.of(1, Brightness.light));
      expect(colourOf(below), ContainerColors.of(0, Brightness.light));
      expect(containerColorOf(gh, Brightness.dark),
          ContainerColors.of(0, Brightness.dark));
    });

    testWidgets('the marks say nothing to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSheet(tester, sites());
      for (final e in find.byType(ContainerMark).evaluate()) {
        expect(
          find.ancestor(of: find.byWidget(e.widget), matching: find.byType(ExcludeSemantics)),
          findsNothing,
          reason: 'the exclusion is the mark\'s own, below it',
        );
        expect(
          find.descendant(of: find.byWidget(e.widget), matching: find.byType(ExcludeSemantics)),
          findsOneWidget,
        );
      }
      handle.dispose();
    });

    testWidgets('collapsing is per site, though tab ids repeat across sites',
        (tester) async {
      await pumpSheet(tester, sites());
      await tester.tap(find.text('All sites'));
      await tester.pump();
      expect(find.text(ddgChild), findsOneWidget);
      // Both sites' first tab is the primary tab, with the same id. Collapse
      // GitHub's: DuckDuckGo's children stay.
      final ghHome = find.ancestor(
          of: find.text('https://github.com/'), matching: find.byType(InkWell));
      await tester.tap(find.descendant(
          of: ghHome.first, matching: find.byIcon(Icons.keyboard_arrow_down)));
      await tester.pump();
      expect(find.text(foreign), findsNothing);
      expect(find.text(ddgChild), findsOneWidget);
    });

    testWidgets('collapsing a subtree from here collapses it in its own tree',
        (tester) async {
      await pumpSheet(tester, sites());
      final row = find.ancestor(of: find.text(hosted), matching: find.byType(InkWell));
      await tester.tap(find.descendant(
          of: row.first, matching: find.byIcon(Icons.keyboard_arrow_down)));
      await tester.pump();
      expect(find.text(below), findsNothing);
      expect(find.text('1 tab hidden'), findsOneWidget);
      await tester.tap(find.text('All sites'));
      await tester.pump();
      expect(find.text(below), findsNothing);
    });

    testWidgets('a double tap on a row opens the tab once and pops only the '
        'sheet', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => TabsSheet(
                    sites: sites(),
                    currentIndex: 0,
                    onOpenTab: (_, id) => opened.add(id),
                    onNewTab: (_) {},
                    onCloseTab: (_, _) {},
                    onCloseSubtree: (_, _) {},
                  ),
                ),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(hosted));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.tap(find.text(hosted), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(opened, ['h']);
      expect(find.text('open sheet'), findsOneWidget,
          reason: 'the second tap must not pop the page under the sheet');
    });
  });
}
