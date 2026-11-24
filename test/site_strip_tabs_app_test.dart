// The site strip with tabs in the running app: the tab count beside it as
// with every navigation, a close through the tabs controller with its undo,
// and one site's tabs at a time on a phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/site_strip.dart';
import 'package:webspace/widgets/tab_chips.dart';
import 'package:webspace/widgets/tab_count_pill.dart';
import 'package:webspace/widgets/tabs_sheet.dart';

import 'helpers/localized.dart';
import 'helpers/model_fixture.dart';
import 'helpers/real_app.dart';

WebViewModel withTabs(String name, {required List<String> titles}) {
  final url = 'https://${name.toLowerCase()}.test';
  final m = WebViewModel(initUrl: url, name: name);
  m.setTabs([
    SiteTab(id: m.activeTabId, url: url, title: titles.first),
    for (var i = 1; i < titles.length; i++)
      SiteTab(id: TabId('${name}t$i'), url: '$url/$i', title: titles[i],
          parentId: m.activeTabId),
  ]);
  return m;
}

Future<void> start(WidgetTester tester,
    {required String navigation, Size size = const Size(1200, 900)}) async {
  setViewSize(tester, size: size);
  await pumpRealApp(
    tester,
    sites: [
      withTabs('Docs', titles: ['Q3 plan', 'Budget 2027']),
      withTabs('Mail', titles: ['Inbox', 'Re: Q3 plan']),
    ],
    prefs: {'siteNavigation': navigation},
  );
  await openWebspace(tester, name: 'All');
  await openSiteFromDrawer(tester, name: 'Docs');
}

void main() {
  testWidgets('the tab button shows the tab count', (tester) async {
    await start(tester, navigation: 'tabButton');
    expect(find.byType(TabCountButton), findsOneWidget);
  });

  testWidgets('the strip shows', (tester) async {
    await start(tester, navigation: 'strip');
    expect(find.byType(SiteStrip), findsOneWidget);
  });

  testWidgets('the strip shows the tabs of the site on screen (TAB-031)',
      (tester) async {
    await start(tester, navigation: 'strip');
    expect(find.widgetWithText(TabChip, 'Q3 plan'), findsOneWidget);
    expect(find.widgetWithText(TabChip, 'Budget 2027'), findsOneWidget);
  });

  for (final navigation in ['strip', 'sidebar', 'tabButton']) {
    testWidgets('TAB-030: with $navigation the app bar keeps the tab-count '
        'button, opening the Tabs sheet; the site menu has no All tabs',
        (tester) async {
      await start(tester, navigation: navigation);
      final button = find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(TabCountButton),
      );
      expect(button, findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
      await settleRealApp(tester);
      expect(find.text('All tabs'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await settleRealApp(tester);
      await tester.tap(button);
      await settleRealApp(tester);
      expect(find.byType(TabsSheet), findsOneWidget);
    });
  }

  testWidgets('a chip closes its tab through the tabs controller, with undo',
      (tester) async {
    await start(tester, navigation: 'strip');
    await tester.tap(find.descendant(
        of: find.widgetWithText(TabChip, 'Budget 2027'),
        matching: find.byTooltip('Close tab')));
    await settleRealApp(tester);
    expect(appSite('Docs').tabs.length, 1);
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settleRealApp(tester);
    expect(appSite('Docs').tabs.length, 2);
  });

  testWidgets('a phone keeps one site open (TAB-031)', (tester) async {
    await start(tester, navigation: 'strip', size: const Size(400, 800));
    expect(find.widgetWithText(TabChip, 'Q3 plan'), findsOneWidget);
    await tester.dragUntilVisible(find.byTooltip("Show Mail's tabs"),
        find.descendant(of: find.byType(SiteStrip), matching: find.byType(ListView)),
        const Offset(-120, 0));
    await tester.ensureVisible(find.byTooltip("Show Mail's tabs"));
    await tester.pump();
    await tester.tap(find.byTooltip("Show Mail's tabs"));
    await settleRealApp(tester);
    expect(find.widgetWithText(TabChip, 'Inbox', skipOffstage: false),
        findsOneWidget);
    expect(find.widgetWithText(TabChip, 'Q3 plan', skipOffstage: false),
        findsNothing);
  });
}
