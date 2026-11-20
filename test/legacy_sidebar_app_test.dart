// The legacy design with the sidebar chosen: the sidebar takes the drawer's
// place, keeping its header (the logo, the webspace, Back to Webspaces) and
// Add Site, its sites as squares unless the tree is chosen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/sidebar_squares.dart';
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
  testWidgets('legacy sidebar keeps the header and Add site, squares by '
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

  testWidgets('the tree, when chosen, keeps the legacy header', (tester) async {
    await start(tester, prefs: {'sidebarStyle': 'tree'});
    expect(inSidebar(find.byType(SiteDrawerHeader)), findsOneWidget);
    expect(inSidebar(find.byType(SidebarSquares)), findsNothing);
  });

  testWidgets('NAV-009 on a phone: Back at the start of the page opens the '
      'sidebar over it, as it opened the drawer, and the next Back closes it', (
    tester,
  ) async {
    await start(
      tester,
      size: const Size(360, 740),
      prefs: {'backOpensMenu': true},
    );
    if (AppPref.sidebarState.value == 'open') {
      await tester.tap(find.byTooltip('Put the sidebar away'));
      await settleRealApp(tester);
    }
    await tester.tap(find.byTooltip('Expand the sidebar'));
    await settleRealApp(tester);
    await tester.tap(inSidebar(find.text('Docs')));
    await settleRealApp(tester);
    await attachWebViews(tester);
    expect(
      AppPref.sidebarState.value,
      'collapsed',
      reason: 'a pick drops the drawer back to the rail',
    );

    await pressBack(tester);
    expect(AppPref.sidebarState.value, 'open');
    await pressBack(tester);
    expect(AppPref.sidebarState.value, 'collapsed');
  });
}
