import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/inappbrowser.dart' show InAppWebViewScreen;
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/webview_proxy.dart' show PlatformInfo;
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// A nested screen runs as its site on the process-wide proxy rule, and its
/// webview outlives the pop that ends it: the route's future completes while
/// the screen is still in the tree, and the plugin destroys the native
/// webview only after it has loaded `about:blank`. So the screen's webview
/// is told to load nothing more before the page lets go of the rule the
/// screen ran on (PROXY-008), as a site's own webview is
/// (`webview_dispose_route_test.dart`).
void main() {
  // The harness fakes the webviews, not the plugin's proxy channel or the
  // startup that reads proxy support: with both here, the rule's writes land
  // and its occupants are the app's.
  const proxyChannel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_proxycontroller',
  );
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, (call) async => null);
    await PlatformInfo.initialize();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, null);
  });

  testWidgets('a nested screen loads nothing more before it leaves the rule '
      '(PROXY-008)', (tester) async {
    final site = WebViewModel(initUrl: 'https://one.test', name: 'One')
      ..tabsEnabled = false
      ..externalLinkMode = ExternalLinkMode.inApp;
    await pumpRealApp(
      tester,
      sites: [
        site,
        WebViewModel(initUrl: 'https://two.test', name: 'Two'),
      ],
      prefs: {'showUrlBar': true},
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
    await tester.enterText(find.byType(TextField).first, 'https://other.test/');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settleRealApp(tester);
    expect(find.byType(InAppWebViewScreen), findsOneWidget);
    await attachWebViews(tester);
    final nested = (use: RouteUse.nested, site: appSite('One').siteId);
    expect(
      ProcessRoute.instance.occupants.keys,
      contains(nested),
      reason: 'the screen runs on its site\'s route',
    );

    webViewSettingsWrites.clear();
    await pressBack(tester);
    expect(find.byType(InAppWebViewScreen), findsNothing);

    final quiet = [
      for (final w in webViewSettingsWrites)
        if (w.settings.blockNetworkLoads == true) w,
    ];
    expect(
      quiet,
      isNotEmpty,
      reason: 'the screen\'s webview was not told to load nothing more',
    );
    expect(
      quiet.first.onRule,
      contains(nested),
      reason: 'it was told only after its site had left the rule',
    );
    expect(ProcessRoute.instance.occupants.keys, isNot(contains(nested)));
  });
}
