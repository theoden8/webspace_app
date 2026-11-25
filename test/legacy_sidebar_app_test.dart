// The legacy design with the sidebar chosen: the sidebar takes the drawer's
// place, keeping its header (the logo, the webspace, Back to Webspaces) and
// Add Site, its sites as squares unless the tree is chosen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/sidebar_squares.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';
import 'package:webspace/widgets/site_drawer.dart';
import 'package:webspace/widgets/site_sidebar.dart';

import 'helpers/localized.dart';
import 'helpers/real_app.dart';

Future<void> start(
  WidgetTester tester, {
  Size size = const Size(1200, 900),
  Map<String, Object> prefs = const {},
}) async {
  setViewSize(tester, size: size);
  await pumpRealApp(
    tester,
    sites: [
      WebViewModel(initUrl: 'https://docs.test', name: 'Docs'),
      WebViewModel(initUrl: 'https://mail.test', name: 'Mail'),
    ],
    prefs: {'legacyDesign': true, 'siteNavigation': 'sidebar', ...prefs},
  );
  await openWebspace(tester, name: 'All');
}

Finder inSidebar(Finder matching) =>
    find.descendant(of: find.byType(SiteSidebar).first, matching: matching);

void main() {
  testWidgets('TAB-036: legacy sidebar keeps the header and Add site, squares by '
      'default, no webspaces button in the app bar', (tester) async {
    await start(tester);
    expect(
      find.byType(SiteDrawer),
      findsNothing,
      reason: 'the sidebar replaces the drawer',
    );
    expect(
      inSidebar(find.byType(SiteDrawerHeader)),
      findsOneWidget,
      reason: 'a picked webspace shows the sidebar, as it opened the drawer',
    );
    expect(inSidebar(find.text('Back to Webspaces')), findsOneWidget);
    expect(inSidebar(find.byType(SidebarSquares)), findsOneWidget);
    expect(inSidebar(find.text('Add Site')), findsOneWidget);

    await tester.longPress(inSidebar(find.text('Mail')));
    await settleRealApp(tester);
    expect(find.text('Delete'), findsOneWidget,
        reason: "a long press gives the site's menu, as the drawer's did");
    await tester.tapAt(const Offset(1100, 850));
    await settleRealApp(tester);

    await tester.tap(inSidebar(find.text('Mail')));
    await settleRealApp(tester);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.apps_rounded),
      ),
      findsNothing,
    );
    expect(find.byTooltip('Open navigation menu'), findsNothing);

    await tester.tap(inSidebar(find.text('Back to Webspaces')));
    await settleRealApp(tester);
    expect(find.byType(WebspacesListScreen), findsOneWidget);
    expect(
      find.byType(SiteSidebar),
      findsOneWidget,
      reason: 'the webspace stays picked, so its sites stay listed',
    );
  });

  testWidgets('the tree, when chosen, keeps the legacy header (TAB-036)', (tester) async {
    await start(tester, prefs: {'sidebarStyle': 'tree'});
    expect(inSidebar(find.byType(SiteDrawerHeader)), findsOneWidget);
    expect(inSidebar(find.byType(SidebarSquares)), findsNothing);
  });

  testWidgets('NAV-009, TAB-033 on a phone: Back at the start of the page opens the '
      'sidebar over it, as it opened the drawer, and the next Back closes it', (
    tester,
  ) async {
    await start(
      tester,
      size: const Size(360, 740),
      prefs: {'backOpensMenu': true},
    );
    // On a phone the squares show only in the drawer over the page.
    final drawer = find.byType(SidebarSquares);
    expect(drawer, findsOneWidget,
        reason: 'a picked webspace opens the drawer, as it did the old one');
    await tester.tap(inSidebar(find.text('Docs')));
    await settleRealApp(tester);
    await attachWebViews(tester);
    expect(drawer, findsNothing, reason: 'a pick drops it back to the rail');

    // Apple offers no Back opens menu (NAV-009), so Back there opens
    // nothing and the drawer is opened by hand; either way Back closes it.
    final offered = backOpensMenuOffered();
    await pressBack(tester);
    expect(drawer, offered ? findsOneWidget : findsNothing);
    if (!offered) {
      await tester.tap(find.byTooltip('Expand the sidebar'));
      await settleRealApp(tester);
      expect(drawer, findsOneWidget);
    }
    await pressBack(tester);
    expect(drawer, findsNothing);
  });

  testWidgets('TAB-036 a hidden sidebar is the legacy drawer, with no arrow '
      'tab', (tester) async {
    await start(tester, prefs: {'sidebarState': 'hidden'});
    expect(find.byType(SiteDrawer), findsOneWidget,
        reason: 'picking a webspace opens the drawer, as it always did');
    await tester.tap(find.descendant(
        of: find.byType(SiteDrawer), matching: find.text('Mail')));
    await settleRealApp(tester);
    expect(find.byType(SidebarArrowTab), findsNothing);
    expect(find.byType(SiteSidebar), findsNothing);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
  });
}
