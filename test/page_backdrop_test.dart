import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

const _follows = 'https://follows.example/';
const _dark = 'https://dark.example/';

/// What a site's webview shows before its page paints: one whose page is
/// told dark is built transparent over the app's dark background, so the
/// engine's white never shows; one told light keeps the engine's opaque
/// white. The surface under it follows each later telling. Whether a device
/// shows a white frame anyway is checked on the device.
void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));

  bool? transparent(WidgetTester tester) => tester
      .widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView).last)
      .platform
      .params
      .initialSettings
      ?.transparentBackground;

  Color? backdrop(WidgetTester tester) => tester
      .widget<ColoredBox>(find
          .descendant(
              of: find.byType(ValueListenableBuilder<Brightness>).last,
              matching: find.byType(ColoredBox))
          .first)
      .color;

  Future<void> open(WidgetTester tester,
      {required Brightness platform, required String name}) async {
    tester.platformDispatcher.platformBrightnessTestValue = platform;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpRealApp(tester, sites: [
      WebViewModel(initUrl: _follows, name: 'Follows'),
      WebViewModel(initUrl: _dark, name: 'Dark', theme: WebViewTheme.dark),
    ]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: name);
    await attachWebViews(tester);
  }

  testWidgets('a page told dark is built transparent over the dark background',
      (tester) async {
    await open(tester, platform: Brightness.dark, name: 'Follows');
    expect(transparent(tester), isTrue);
    expect(backdrop(tester), appBackground(Brightness.dark));
  });

  testWidgets('a page told light keeps the engine\'s opaque background',
      (tester) async {
    await open(tester, platform: Brightness.light, name: 'Follows');
    expect(transparent(tester), isFalse);
    expect(backdrop(tester), appBackground(Brightness.light));
  });

  testWidgets('a site with its own dark theme is built dark in a light app',
      (tester) async {
    await open(tester, platform: Brightness.light, name: 'Dark');
    expect(transparent(tester), isTrue);
    expect(backdrop(tester), appBackground(Brightness.dark));
  });

  testWidgets('the surface under the webview follows the scheme told later',
      (tester) async {
    await open(tester, platform: Brightness.dark, name: 'Follows');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await settleRealApp(tester);
    expect(transparent(tester), isTrue,
        reason: 'a built webview keeps its settings');
    expect(backdrop(tester), appBackground(Brightness.light));
  });
}
