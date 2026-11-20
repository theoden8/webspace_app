// The Tabs sheet's tree hosted as the sidebar and the phone's drawer: every
// tree at once, no sheet chrome, a pick that leaves the route alone, and the
// sheet's folding, close and undo unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tabs_sheet.dart';

import 'helpers/localized.dart';
import 'helpers/tab_chain.dart';

Future<void> pumpTree(
  WidgetTester tester, {
  required List<TabsSheetSite> sites,
  TabsSheetHost host = TabsSheetHost.sidebar,
  void Function(WebViewModel site, {required TabId tabId})? onOpenTab,
  TabsSheetClose? onCloseTab,
}) async {
  setViewSize(tester, size: const Size(320, 900));
  await pumpLocalized(tester,
      home: Scaffold(
        body: TabsSheet(
          host: host,
          sites: sites,
          currentIndex: 0,
          onOpenTab: onOpenTab ?? (_, {required tabId}) {},
          onNewTab: (_) {},
          onCloseTab: onCloseTab ??
              (_, {required tabId}) async =>
                  (listing: (sites: sites, wayBack: null), kept: null),
          onCloseSubtree: (_, {required tabId}) async =>
              (listing: (sites: sites, wayBack: null), kept: null),
        ),
      ));
  await tester.pump();
}

TabsSheetSite listed(WebViewModel model,
        {bool current = false, bool tabsOn = true}) =>
    TabsSheetSite(
        model: model, isCurrent: current, isLoaded: current, tabsOn: tabsOn);

void main() {
  testWidgets('the sidebar lists every tree, with no scope switch or handle',
      (tester) async {
    final docs = siteWithChain('Docs',
        urls: ['https://docs.test/a', 'https://docs.test/b']);
    final mail = siteWithChain('Mail',
        urls: ['https://mail.test/a', 'https://mail.test/b']);
    await pumpTree(tester, sites: [listed(docs, current: true), listed(mail)]);
    expect(find.textContaining('Docs'), findsWidgets);
    expect(find.textContaining('Mail'), findsWidgets);
    expect(find.text('This site'), findsNothing);
  });

  testWidgets('a site with tabs off is one row that opens it, with no close',
      (tester) async {
    final docs = siteWithChain('Docs',
        urls: ['https://docs.test/a', 'https://docs.test/b']);
    final bank = WebViewModel(initUrl: 'https://bank.test', name: 'Bank');
    WebViewModel? opened;
    await pumpTree(tester,
        sites: [listed(docs, current: true), listed(bank, tabsOn: false)],
        onOpenTab: (site, {required tabId}) => opened = site);
    final row = find.text('Bank');
    expect(row, findsOneWidget);
    expect(
        find.descendant(
            of: find.ancestor(of: row, matching: find.byType(InkWell)).first,
            matching: find.byTooltip('Close tab')),
        findsNothing);
    await tester.tap(row);
    await tester.pump();
    expect(opened, same(bank));
  });

  testWidgets('a pick in the sidebar leaves the route where it is',
      (tester) async {
    final docs = siteWithChain('Docs',
        urls: ['https://docs.test/a', 'https://docs.test/b']);
    TabId? picked;
    await pumpTree(tester,
        sites: [listed(docs, current: true)],
        onOpenTab: (_, {required tabId}) => picked = tabId);
    await tester.tap(find.text('https://docs.test/b'));
    await tester.pumpAndSettle();
    expect(picked, docs.tabs[1].id);
    expect(find.byType(TabsSheet), findsOneWidget);
  });

  testWidgets('a tab subtree folds and says how many it holds (TAB-034)',
      (tester) async {
    final docs = siteWithChain('Docs', urls: [
      'https://docs.test/a',
      'https://docs.test/b',
      'https://docs.test/c',
    ]);
    await pumpTree(tester, sites: [listed(docs, current: true)]);
    await tester.tap(find.byTooltip('Hide the tabs opened from this one').first);
    await tester.pump();
    expect(find.text('https://docs.test/b'), findsNothing);
    expect(find.text('2 tabs hidden'), findsOneWidget);
  });

  testWidgets('a site folds shut and opens again', (tester) async {
    final docs = siteWithChain('Docs',
        urls: ['https://docs.test/a', 'https://docs.test/b']);
    await pumpTree(tester, sites: [listed(docs, current: true)]);
    await tester.tap(find.byTooltip("Hide this site's tabs"));
    await tester.pump();
    expect(find.text('https://docs.test/b'), findsNothing);
    await tester.tap(find.byTooltip("Show this site's tabs"));
    await tester.pump();
    expect(find.text('https://docs.test/b'), findsOneWidget);
  });

  testWidgets('a new listing from the host redraws the sidebar',
      (tester) async {
    final docs = siteWithChain('Docs', urls: ['https://docs.test/a']);
    await pumpTree(tester, sites: [listed(docs, current: true)]);
    final mail = siteWithChain('Mail',
        urls: ['https://mail.test/a', 'https://mail.test/b']);
    await pumpTree(tester, sites: [listed(docs, current: true), listed(mail)]);
    expect(find.text('https://mail.test/b'), findsOneWidget);
  });

  testWidgets('the drawer sets its rows for a finger', (tester) async {
    final docs = siteWithChain('Docs',
        urls: ['https://docs.test/a', 'https://docs.test/b']);
    await pumpTree(tester,
        sites: [listed(docs, current: true)], host: TabsSheetHost.drawer);
    final row = find
        .ancestor(
            of: find.text('https://docs.test/b'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
  });
}
