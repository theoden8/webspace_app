// The sidebar in full screen, as the In full screen choice says: hidden shows
// nothing, kept keeps it docked, and Button gives the arrow tab, which shows
// the sidebar over the page until its collapse button puts it away.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';
import 'package:webspace/widgets/sidebar_squares.dart';
import 'package:webspace/widgets/site_navigation_frame.dart';
import 'package:webspace/widgets/site_sidebar.dart';

import 'helpers/localized.dart';
import 'helpers/real_app.dart';

Future<void> start(WidgetTester tester, {required String inFullscreen}) async {
  setViewSize(tester, size: const Size(1200, 900));
  await pumpRealApp(
    tester,
    sites: [
      WebViewModel(
        initUrl: 'https://a.example.test',
        name: 'A',
        fullscreenMode: true,
      ),
      WebViewModel(initUrl: 'https://b.example.test', name: 'B'),
    ],
    prefs: {
      'legacyDesign': false,
      'siteNavigation': 'sidebar',
      'fullscreenNavigation': inFullscreen,
    },
  );
  await openWebspace(tester, name: 'All');
  await openSiteFromDrawer(tester, name: 'A');
  // The full screen hint covers the page's corner until it times out.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// The page's left edge: where the sidebar docked beside it ends.
double pageLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const ValueKey('site-stack'))).dx;

Finder floating() => find.descendant(
  of: find.byType(SiteNavigationFrame),
  matching: find.byWidgetPredicate((w) => w is Material && w.elevation == 8),
);

void main() {
  testWidgets('full screen hidden shows nothing', (tester) async {
    await start(tester, inFullscreen: 'hidden');
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(SidebarArrowTab), findsNothing);
    expect(find.byType(SidebarSquares), findsNothing);
    expect(pageLeft(tester), 0);
  });

  testWidgets('kept keeps the sidebar docked', (tester) async {
    await start(tester, inFullscreen: 'kept');
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(SidebarSquares), findsOneWidget);
    expect(pageLeft(tester), AppPref.sidebarWidth.value);
    expect(find.byType(SidebarArrowTab), findsNothing);
  });

  testWidgets('button: arrow tab reveals the sidebar over the page, collapse '
      'button puts it away, leaving restores', (tester) async {
    await start(tester, inFullscreen: 'button');
    expect(find.byType(SidebarSquares), findsNothing);
    expect(pageLeft(tester), 0);

    await tester.tap(find.byType(SidebarArrowTab));
    await settleRealApp(tester);
    expect(
      find.descendant(of: floating(), matching: find.byType(SiteSidebar)),
      findsOneWidget,
    );
    expect(pageLeft(tester), 0, reason: 'over the page, never beside it');
    expect(find.byType(SidebarArrowTab), findsNothing);

    await tester.tap(find.byTooltip('Put the sidebar away'));
    await settleRealApp(tester);
    expect(find.byType(SidebarSquares), findsNothing);
    expect(find.byType(SidebarArrowTab), findsOneWidget);
    expect(
      AppPref.sidebarState.value,
      'open',
      reason: 'putting it away in full screen leaves the state as it was',
    );

    await tester.tap(find.byType(SidebarArrowTab));
    await settleRealApp(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SidebarSquares),
        matching: find.text('B'),
      ),
    );
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsOneWidget, reason: 'B is not full screen');
    expect(pageLeft(tester), AppPref.sidebarWidth.value);
  });
}
