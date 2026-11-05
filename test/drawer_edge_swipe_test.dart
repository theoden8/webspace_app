import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_drawer.dart';

import 'helpers/real_app.dart';

/// A swipe in from the left edge, as a finger starting on the screen's edge.
Future<void> _swipeFromEdge(WidgetTester tester) async {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  await tester.dragFrom(Offset(1, size.height / 2), const Offset(300, 0));
  await settleRealApp(tester);
}

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));

  testWidgets(
      'NAV-003: an edge swipe opens the drawer over the webspace list and '
      'not over a site', (tester) async {
    await pumpRealApp(
      tester,
      sites: [WebViewModel(initUrl: 'https://example.test', name: 'Site')],
    );
    await openWebspace(tester, name: 'All');
    expect(find.byType(SiteDrawer), findsOneWidget,
        reason: 'opening a webspace shows its sites in the drawer');
    await pressBack(tester);
    expect(find.byType(SiteDrawer), findsNothing);

    await _swipeFromEdge(tester);
    expect(find.byType(SiteDrawer), findsOneWidget,
        reason: 'no site on screen: the swipe opens the drawer');
    await openSiteFromDrawer(tester, name: 'Site');
    await attachWebViews(tester);
    expect(find.byType(SiteDrawer), findsNothing);

    await _swipeFromEdge(tester);
    expect(find.byType(SiteDrawer), findsNothing,
        reason: 'a site on screen keeps the edge for its own gestures');
  });
}
