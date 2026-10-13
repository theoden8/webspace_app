import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_tab_strip.dart';
import 'package:webspace/widgets/site_webview_stack.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';

import 'helpers/real_app.dart';

/// FS-012: the tab strip runs along the edge the user picked, with the page
/// between it and the other edge.
void main() {
  for (final onTop in [true, false]) {
    testWidgets('a pinned strip set to the ${onTop ? 'top' : 'bottom'} '
        'sits there, the page beside it', (tester) async {
      await pumpRealApp(
        tester,
        sites: [WebViewModel(initUrl: 'https://example.test', name: 'Site')],
        prefs: {'showTabStrip': true, 'tabStripOnTop': onTop},
      );
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'Site');

      final strip = tester.getRect(find.byType(SiteTabStrip));
      final page = tester.getRect(find.byType(SiteWebViewStack));
      final screen = tester.getRect(find.byType(Scaffold).first);
      if (onTop) {
        expect(strip.top, tester.getRect(find.byType(AppBar)).bottom,
            reason: 'right under the app bar');
        expect(page.top, greaterThanOrEqualTo(strip.bottom));
      } else {
        expect(strip.bottom, screen.bottom);
        expect(page.bottom, lessThanOrEqualTo(strip.top));
      }
    });
  }

  testWidgets('leaving full screen with a revealed top strip keeps the '
      'webviews', (tester) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(
            initUrl: 'https://example.test', name: 'Site', fullscreenMode: true),
      ],
      prefs: {'tabBarButton': true, 'tabStripOnTop': true, 'showUrlBar': true},
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Site');
    expect(find.byType(AppBar), findsNothing, reason: 'opened in full screen');

    // The full screen hint covers the button's corner until it times out.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.tap(find.byType(TabBarCornerButton));
    await settleRealApp(tester);
    expect(find.byType(SiteTabStrip), findsOneWidget);
    final before = tester.element(find.byType(SiteWebViewStack));

    // The strip leaves the top of the body as the URL bar joins its bottom.
    await tester.tap(find.byTooltip('Menu'));
    await settleRealApp(tester);
    await tester.tap(find.text('Exit Full Screen'));
    await settleRealApp(tester);
    expect(find.byType(SiteTabStrip), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);

    expect(tester.element(find.byType(SiteWebViewStack)), same(before),
        reason: 'the site stack was updated in place, not remounted');
  });
}
