import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// iOS runs `OpenSiteIntent.perform` after it has brought a running app to
/// the front, so the resume can ask for the launch before it is stored. The
/// plugin then says a launch is pending, and the app opens it: without that,
/// the site the app was left on stayed on screen (HS-006).
void main() {
  const channel = MethodChannel('org.codeberg.theoden8.webspace/shortcuts');
  const github = 'https://github.example.test/';
  const ddg = 'https://ddg.example.test/';

  testWidgets('a shortcut stored after the resume asked opens its site once '
      'the plugin says it is pending (HS-006)', (tester) async {
    ShortcutService.debugAppIntentsOverride = true;
    addTearDown(() => ShortcutService.debugAppIntentsOverride = null);
    final ddgSite = WebViewModel(initUrl: ddg, name: 'DDG');
    Map<String, String>? pending;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method != 'getLaunchSiteId') return null;
      final launch = pending;
      pending = null;
      return launch;
    });

    await pumpRealApp(tester, sites: [
      WebViewModel(initUrl: github, name: 'GitHub'),
      ddgSite,
    ]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'GitHub');

    Iterable<String> built() => tester
        .widgetList<inapp.InAppWebView>(find.byType(inapp.InAppWebView))
        .map((v) => v.platform.params.initialUrlRequest!.url.toString());
    expect(built(), [github]);

    pending = {'siteId': appSite('DDG').siteId, 'url': ddg};
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('launchPending')),
      (_) {},
    );
    await settleRealApp(tester);

    expect(built(), contains(ddg));
    expect(pending, isNull, reason: 'the launch was read once');
  });
}
