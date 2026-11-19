import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/inappbrowser.dart' show InAppWebViewScreen;
import 'package:webspace/services/webview_back.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_webview_controller.dart';
import 'helpers/real_app.dart';

/// NAV-008: the system back gesture on a nested screen walks the nested
/// page's own history first and closes the screen only at its start, by the
/// one back step every surface takes (NAV-002); the app bar's back arrow
/// closes it whatever the history.
void main() {
  group('the back step', () {
    late FakeWebViewController view;

    setUp(() => view = FakeWebViewController()
      ..pages = ['https://a.test/', 'https://a.test/next']);

    Future<BackStep> step({required bool trusts, bool live = true}) =>
        stepBack(view,
            trustsCanGoBack: trusts, goBack: view.goBack, live: () => live);

    test('NAV-008: where canGoBack() is trusted it alone decides', () async {
      expect(await step(trusts: true), BackStep.moved);
      expect(view.pages, ['https://a.test/']);
      expect(await step(trusts: true), BackStep.atStart);
      expect(view.calls.where((c) => c == 'goBack'), hasLength(1),
          reason: 'no goBack() at the start of history');
    });

    test('NAV-008: elsewhere goBack() is tried and the URL decides, past a '
        'canGoBack() that misses pushState entries', () async {
      view.canGoBackAnswer = false;
      expect(await step(trusts: false), BackStep.moved);
      expect(view.pages, ['https://a.test/']);
      expect(await step(trusts: false), BackStep.atStart);
    });

    test('NAV-008: a back that lands after goBack() returns is read after '
        'the settle', () async {
      view
        ..canGoBackAnswer = false
        ..backLag = kBackSettle ~/ 3;
      expect(await step(trusts: false), BackStep.moved);
    });

    test('NAV-008: a view gone while the step was out ends it', () async {
      expect(await step(trusts: false, live: false), BackStep.abandoned);
      expect(await step(trusts: true, live: false), BackStep.abandoned);
    });
  });

  group('on the nested screen', () {
    Future<void> openNested(WidgetTester tester) async {
      final site = WebViewModel(initUrl: 'https://shop.test', name: 'Shop')
        ..externalLinkMode = ExternalLinkMode.inApp;
      await pumpRealApp(tester, sites: [site], prefs: {'showUrlBar': true});
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'Shop');
      await attachWebViews(tester);
      await tester.enterText(
          find.byType(TextField).first, 'https://other.test/checkout');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settleRealApp(tester);
      expect(find.byType(InAppWebViewScreen), findsOneWidget);
      await attachWebViews(tester);
    }

    testWidgets('NAV-008: back walks the nested history, then closes the '
        'screen', (tester) async {
      await openNested(tester);
      await pageMovesTo(tester, url: 'https://other.test/pay');

      await pressBack(tester);
      await tester.pump(kBackSettle);
      await settleRealApp(tester);
      expect(find.byType(InAppWebViewScreen), findsOneWidget,
          reason: 'there was a page to go back to');

      await pressBack(tester);
      await tester.pump(kBackSettle);
      await settleRealApp(tester);
      expect(find.byType(InAppWebViewScreen), findsNothing);
    });

    testWidgets('NAV-008: a second gesture while the first is out drops',
        (tester) async {
      await openNested(tester);
      await pageMovesTo(tester, url: 'https://other.test/pay');
      await pageMovesTo(tester, url: 'https://other.test/done');
      final calls = webViewCalls.length;

      final first = tester.binding.handlePopRoute();
      final second = tester.binding.handlePopRoute();
      await tester.pump(kBackSettle);
      await settleRealApp(tester);
      await Future.wait([first, second]);
      expect(webViewCalls.skip(calls).where((c) => c == #goBack), hasLength(1));
      expect(find.byType(InAppWebViewScreen), findsOneWidget);
    });

    testWidgets('NAV-008: the app bar\'s back arrow closes the screen over '
        'its history', (tester) async {
      await openNested(tester);
      await pageMovesTo(tester, url: 'https://other.test/pay');
      final calls = webViewCalls.length;

      await tester.tap(find.descendant(
          of: find.byType(InAppWebViewScreen),
          matching: find.byType(BackButtonIcon)));
      await settleRealApp(tester);
      expect(find.byType(InAppWebViewScreen), findsNothing);
      expect(webViewCalls.skip(calls), isNot(contains(#goBack)));
    });
  });
}
