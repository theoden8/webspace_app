import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_tab.dart';
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
  void Function(int, String)? onCloseTab,
  void Function(int, String)? onCloseSubtree,
  void Function(int)? onCloseParked,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: TabsSheet(
        sites: sites,
        currentIndex: 0,
        onOpenTab: onOpenTab ?? (_, _) {},
        onNewTab: onNewTab ?? (_) {},
        onCloseTab: onCloseTab ?? (_, _) {},
        onCloseSubtree: onCloseSubtree ?? (_, _) {},
        onCloseParked: onCloseParked ?? (_) {},
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('TAB-008 — the tab list', () {
    testWidgets('lists every tab of the site, with the open one marked',
        (tester) async {
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
        'https://github.com/pull/601',
      ]);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true),
      ]);

      expect(find.textContaining('github.com'), findsWidgets);
      expect(find.text('GitHub · 3 tabs'), findsOneWidget);
      // Exactly one row is the loaded one: the active tab of the site on
      // screen. Every other tab is stored, not running.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a site on one tab says so in the singular', (tester) async {
      final site = siteWithChain('Mastodon', ['https://mastodon.social/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true),
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
        TabsSheetSite(index: 0, model: site, isCurrent: true),
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
        [TabsSheetSite(index: 7, model: site, isCurrent: true)],
        onNewTab: (i) => opened = i,
      );
      await tester.tap(find.text('New tab'));
      await tester.pump();
      expect(opened, 7);
    });

    testWidgets('closing a row reports that tab', (tester) async {
      String? closed;
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
      ]);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: site, isCurrent: true)],
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
        [TabsSheetSite(index: 0, model: site, isCurrent: true)],
        onCloseSubtree: (_, id) => closed = id,
      );
      // Only the parent row has the control: the leaf has nothing under it.
      expect(find.byIcon(Icons.layers_clear_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.layers_clear_outlined));
      await tester.pump();
      expect(closed, site.tabs.first.id);
    });

    testWidgets('closing the parked tabs is offered only when there are some',
        (tester) async {
      final one = siteWithChain('Solo', ['https://solo.test/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: one, isCurrent: true),
      ]);
      expect(find.textContaining('parked'), findsNothing);

      final many = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
        'https://github.com/issues',
      ]);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: many, isCurrent: true),
      ]);
      expect(find.text('Close 2 parked tabs'), findsOneWidget);
    });

    testWidgets('the all-sites scope appears only with more than one site',
        (tester) async {
      final a = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true),
      ]);
      expect(find.text('All sites'), findsNothing);

      final b = siteWithChain('Mastodon', ['https://mastodon.social/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true),
        TabsSheetSite(index: 1, model: b, isCurrent: false),
      ]);
      expect(find.text('All sites'), findsOneWidget);
      expect(find.text('This site'), findsOneWidget);

      await tester.tap(find.text('All sites'));
      await tester.pump();
      // Both sites' headings are present once the scope widens.
      expect(find.text('GitHub · 1 tab'), findsWidgets);
      expect(find.text('Mastodon · 1 tab'), findsOneWidget);
    });

    testWidgets('no tab of a backgrounded site is marked as loaded',
        (tester) async {
      final a = siteWithChain('GitHub', ['https://github.com/']);
      final b = siteWithChain('Mastodon', [
        'https://mastodon.social/',
        'https://mastodon.social/@a',
      ]);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true),
        TabsSheetSite(index: 1, model: b, isCurrent: false),
      ]);
      await tester.tap(find.text('All sites'));
      await tester.pump();
      // Only one webview exists across every site, and it belongs to the site
      // on screen (TAB-002).
      expect(find.text('open'), findsOneWidget);
    });
  });
}
