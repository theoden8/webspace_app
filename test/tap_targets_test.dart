import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// Flutter's tap target guidelines, Android's 48dp and iOS's 44pt, over the
/// chrome a site is used through: the webspaces, a site with its tab strip,
/// the drawer, and App Settings with each screen it opens.
void main() {
  Future<void> meetsBoth(WidgetTester tester, {required String screen}) async {
    final semantics = tester.ensureSemantics();
    for (final guideline in [androidTapTargetGuideline, iOSTapTargetGuideline]) {
      final result = await guideline.evaluate(tester);
      expect(result.passed, isTrue, reason: '$screen: ${result.reason}');
    }
    semantics.dispose();
  }

  testWidgets('every tap target of the chrome meets both platforms\' floor',
      (tester) async {
    await pumpRealApp(tester,
        sites: [WebViewModel(initUrl: 'https://example.com', name: 'Example')],
        prefs: {'showTabStrip': true});
    await meetsBoth(tester, screen: 'the webspaces');
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Example');
    await meetsBoth(tester, screen: 'a site with its tab strip');
    await tester.tap(find.byTooltip('Open navigation menu'));
    await settleRealApp(tester);
    await meetsBoth(tester, screen: 'the drawer');

    await tester.tap(find.text('Back to Webspaces'));
    await settleRealApp(tester);
    await tester.tap(find.byTooltip('App Settings'));
    await settleRealApp(tester);
    await meetsBoth(tester, screen: 'App Settings');
    for (final row in [
      'Appearance',
      'Behaviour',
      'Network',
      'Privacy',
      'Backup and archives',
    ]) {
      await tester.tap(find.text(row).first);
      await settleRealApp(tester);
      await meetsBoth(tester, screen: row);
      await tester.binding.handlePopRoute();
      await settleRealApp(tester);
    }
  });
}
