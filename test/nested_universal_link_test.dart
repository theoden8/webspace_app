import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/inappbrowser.dart' show InAppWebViewScreen;
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// IOS-UL-006. A link tap in a nested screen goes through the Universal Link
/// bypass as one in the site's own webview does: the tap is cancelled and
/// loaded again by the app, which WebKit does not hand to an installed app.
void main() {
  setUp(() => WebViewFactory.debugUniversalLinkBypass = true);
  tearDown(() => WebViewFactory.debugUniversalLinkBypass = null);

  /// What [view] decides for a tap on a link to [url], and what it loaded.
  Future<(inapp.NavigationActionPolicy?, List<String>)> tap(
    WidgetTester tester, {
    required inapp.InAppWebView view,
    required String url,
  }) async {
    final controller = await webViewControllerOf(tester, view: view);
    webViewLoads.clear();
    final policy = await tester.runAsync(() async =>
        view.platform.params.shouldOverrideUrlLoading!(
          controller,
          inapp.NavigationAction(
            request: inapp.URLRequest(url: inapp.WebUri(url)),
            isForMainFrame: true,
            hasGesture: true,
            navigationType: inapp.NavigationType.LINK_ACTIVATED,
          ),
        ));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    return (policy, [for (final r in webViewLoads) '${r.url}']);
  }

  Future<void> openSite(WidgetTester tester) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(initUrl: 'https://one.test', name: 'One')
          ..tabsEnabled = false
          ..externalLinkMode = ExternalLinkMode.inApp,
      ],
      prefs: {'showUrlBar': true},
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
  }

  testWidgets('a tap in the site\'s own webview is loaded again by the app',
      (tester) async {
    await openSite(tester);
    final (policy, loads) = await tap(tester,
        view: tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView)),
        url: 'https://one.test/place');
    expect(policy, inapp.NavigationActionPolicy.CANCEL);
    expect(loads, ['https://one.test/place']);
  });

  testWidgets('a tap in a nested screen is loaded again by the app '
      '(IOS-UL-006)', (tester) async {
    await openSite(tester);
    await tester.enterText(find.byType(TextField).first, 'https://other.test/');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settleRealApp(tester);
    expect(find.byType(InAppWebViewScreen), findsOneWidget);
    await attachWebViews(tester);
    final nested = tester.widget<inapp.InAppWebView>(find.descendant(
        of: find.byType(InAppWebViewScreen),
        matching: find.byType(inapp.InAppWebView)));

    final (policy, loads) =
        await tap(tester, view: nested, url: 'https://other.test/place');
    expect(policy, inapp.NavigationActionPolicy.CANCEL);
    expect(loads, ['https://other.test/place']);

    final (again, reloads) =
        await tap(tester, view: nested, url: 'https://other.test/place');
    expect(again, inapp.NavigationActionPolicy.ALLOW,
        reason: 'the app\'s own load of it passes');
    expect(reloads, isEmpty);
  });
}
