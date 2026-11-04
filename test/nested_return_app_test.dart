import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/inappbrowser.dart' show InAppWebViewScreen;
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/navigation_action_reading.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// NESTED-017 through the shipped app: a nested screen whose page heads back
/// into the site closes, and the tab it was opened over loads the page, as a
/// browser's window closes into the page that opened it. The engine's half
/// is `navigation_decision_engine_test.dart`; here the page builds the
/// screen's opener and the link controller loads the tab, so a gap between
/// them fails too.
void main() {
  const checkout = 'https://other.test/checkout';

  Future<void> openNested(
    WidgetTester tester, {
    required WebViewModel site,
  }) async {
    await pumpRealApp(tester, sites: [site], prefs: {'showUrlBar': true});
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: site.name);
    await attachWebViews(tester);
    await tester.enterText(find.byType(TextField).first, checkout);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settleRealApp(tester);
    expect(find.byType(InAppWebViewScreen), findsOneWidget);
    await attachWebViews(tester);
  }

  WebViewModel shop({required bool tabs}) =>
      WebViewModel(initUrl: 'https://shop.test', name: 'Shop')
        ..tabsEnabled = tabs
        ..externalLinkMode = ExternalLinkMode.inApp;

  for (final tabs in [false, true]) {
    testWidgets('NESTED-017: a tap into the site closes the screen into the '
        'tab it was opened over, tabs $tabs', (tester) async {
      await openNested(tester, site: shop(tabs: tabs));
      final before = appSite('Shop');
      final tabIds = [for (final t in before.tabs) t.id];
      final active = before.activeTabId;

      await tapLink(tester, url: 'https://shop.test/orders/7');

      expect(find.byType(InAppWebViewScreen), findsNothing);
      final after = appSite('Shop');
      expect(after.currentUrl, 'https://shop.test/orders/7');
      expect([for (final t in after.tabs) t.id], tabIds,
          reason: 'the tab it came from loads it: no child tab');
      expect(after.activeTabId, active);
    });
  }

  testWidgets('NESTED-017: the page sent home by a script closes the screen '
      'too', (tester) async {
    await openNested(tester, site: shop(tabs: true));

    final policy = await pageNavigates(tester,
        url: 'https://shop.test/paid?order=7', hop: PageHop.script);

    expect(policy, inapp.NavigationActionPolicy.CANCEL);
    expect(find.byType(InAppWebViewScreen), findsNothing);
    expect(appSite('Shop').currentUrl, 'https://shop.test/paid?order=7');
  });

  // On a Linux host a form is a main frame the plugin only guessed
  // (NESTED-013), so this holds there before the replay check is asked; the
  // macOS runner is where it holds by that check.
  testWidgets('NESTED-017: a form posted home loads in the screen, its body '
      'kept', (tester) async {
    await openNested(tester, site: shop(tabs: true));
    final url = appSite('Shop').currentUrl;

    final policy = await pageNavigates(tester,
        url: 'https://shop.test/3ds/return', hop: PageHop.formPost);

    expect(policy, inapp.NavigationActionPolicy.ALLOW);
    expect(find.byType(InAppWebViewScreen), findsOneWidget);
    expect(appSite('Shop').currentUrl, url);
  });

  testWidgets('NESTED-017: a frame of the site\'s domain leaves the screen '
      'open', (tester) async {
    await openNested(tester, site: shop(tabs: true));

    final policy = await pageNavigates(tester,
        url: 'https://shop.test/widget', hop: PageHop.frame);

    expect(policy, inapp.NavigationActionPolicy.ALLOW);
    expect(find.byType(InAppWebViewScreen), findsOneWidget);
  });

  testWidgets('NESTED-017: a link elsewhere still loads in the screen',
      (tester) async {
    await openNested(tester, site: shop(tabs: true));

    await tapLink(tester, url: 'https://third.test/help');

    expect(find.byType(InAppWebViewScreen), findsOneWidget);
  });

  for (final mode in [ExternalLinkMode.browser, ExternalLinkMode.block]) {
    testWidgets('NESTED-009: in the ${mode.name} mode the site\'s own domain '
        'is not another site\'s, and comes home', (tester) async {
      // A claimed domain opens nested in every mode, so the screen can be
      // up at all.
      await openNested(
        tester,
        site: shop(tabs: true)
          ..externalLinkMode = mode
          ..domainClaims = [
            DomainClaim.baseDomain('shop.test'),
            DomainClaim.baseDomain('other.test'),
          ],
      );

      await tapLink(tester, url: 'https://shop.test/orders/7');

      expect(find.byType(InAppWebViewScreen), findsNothing);
      expect(appSite('Shop').currentUrl, 'https://shop.test/orders/7');
    });
  }

  group('NESTED-016, NESTED-017: what a navigation can replay', () {
    inapp.NavigationAction action({
      String? method,
      inapp.NavigationType? type,
    }) =>
        inapp.NavigationAction(
          request: inapp.URLRequest(
              url: inapp.WebUri('https://shop.test/'), method: method),
          isForMainFrame: true,
          navigationType: type,
        );

    test('a link or a redirect, asked by GET or with no method', () {
      for (final method in [null, 'GET', 'get']) {
        expect(
            action(method: method, type: inapp.NavigationType.LINK_ACTIVATED)
                .replayable,
            isTrue,
            reason: '$method');
      }
      expect(action().replayable, isTrue);
    });

    test('not a form, whatever method the platform reports (Linux says GET)',
        () {
      for (final type in [
        inapp.NavigationType.FORM_SUBMITTED,
        inapp.NavigationType.FORM_RESUBMITTED,
      ]) {
        expect(action(method: 'GET', type: type).replayable, isFalse,
            reason: '$type');
      }
    });

    test('not a method other than GET', () {
      expect(action(method: 'POST').replayable, isFalse);
    });
  });
}
