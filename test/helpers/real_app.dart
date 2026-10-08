import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// The shipped `WebSpaceApp`, pumped in a widget test: page state, drawer,
/// app bar and sheets are the real ones, started from [sites] and
/// [webspaces] the way a cold start reads them from disk. Only the platform
/// is faked: the webview draws nothing, and a page acts through the
/// callbacks the platform would call ([tapLink]).
///
/// The models the app runs are decoded from the stored JSON, so they are not
/// [sites]; read them back with [appSite].
Future<void> pumpRealApp(
  WidgetTester tester, {
  required List<WebViewModel> sites,
  List<Webspace> webspaces = const [],
  bool siteTabs = true,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'webViewModels': [for (final s in sites) jsonEncode(s.toJson())],
    'webspaces': [
      jsonEncode(Webspace.all().toJson()),
      for (final w in webspaces) jsonEncode(w.toJson()),
    ],
    'selectedWebspaceId': kAllWebspaceId,
    'currentIndex': 10000,
    'developerMode': siteTabs,
    'experimentalSiteTabs': siteTabs,
    ...prefs,
  });
  FlutterSecureStorage.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: 'WebSpace',
    packageName: 'org.codeberg.theoden8.webspace',
    version: '9.9.9',
    buildNumber: '42',
    buildSignature: '',
    installerStore: null,
  );
  AndroidInAppWebViewPlatform.registerWith();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('dexterous.com/flutter/local_notifications'),
    (call) async => call.method == 'initialize' ? true : null,
  );
  messenger.setMockMethodCallHandler(
    SystemChannels.platform_views,
    (call) async => call.method == 'create' ? 0 : null,
  );
  await DeveloperModeService.instance.initialize();
  await ExperimentalFeaturesService.instance.initialize();
  await tester.pumpWidget(app.WebSpaceApp());
  await settleRealApp(tester);
}

/// Startup and site activation do real I/O, which a fake-async pump alone
/// never lets finish.
Future<void> settleRealApp(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The app's own model of the site named [name].
WebViewModel appSite(String name) =>
    app.debugWebViewModels!.singleWhere((m) => m.name == name);

/// Pick a webspace on the start screen.
Future<void> openWebspace(WidgetTester tester, {required String name}) async {
  final entry = find.descendant(
    of: find.byType(ListTile),
    matching: find.text(name),
  );
  await tester.tap(entry.first);
  await settleRealApp(tester);
}

/// Bring the site named [name] on screen from the drawer.
Future<void> openSiteFromDrawer(WidgetTester tester,
    {required String name}) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await settleRealApp(tester);
  await tester.tap(find.text(name).last);
  await settleRealApp(tester);
}

Future<void> openTabsSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Tabs'));
  await settleRealApp(tester);
}

/// A tap on a link to [url] in the page on screen, as the platform reports
/// it: a main-frame navigation with a user gesture. Android reads the gesture
/// from `hasGesture`, Apple hosts from the navigation type, so both are set
/// or the tap reads as script-driven on a macOS runner.
Future<void> tapLink(WidgetTester tester, {required String url}) async {
  final views = find.byType(inapp.InAppWebView).evaluate().toList();
  expect(views, hasLength(1), reason: 'one page on screen to tap in');
  final view = views.single.widget as inapp.InAppWebView;
  await tester.runAsync(() async {
    await view.platform.params.shouldOverrideUrlLoading!(
      _FakeWebViewController(),
      inapp.NavigationAction(
        request: inapp.URLRequest(url: inapp.WebUri(url)),
        isForMainFrame: true,
        hasGesture: true,
        navigationType: inapp.NavigationType.LINK_ACTIVATED,
      ),
    );
  });
  await settleRealApp(tester);
}

/// Hand every webview the app has built a controller, as the platform does
/// once a webview exists. The page treats a site without one as still
/// loading, so Back, for one, is not spent on its tabs until this runs.
Future<void> attachWebViews(WidgetTester tester) async {
  for (final e in find.byType(inapp.InAppWebView).evaluate()) {
    final view = e.widget as inapp.InAppWebView;
    if (!_attached.add(view)) continue;
    await tester.runAsync(() async {
      view.platform.params.onWebViewCreated?.call(_FakeWebViewController());
    });
  }
  await settleRealApp(tester);
}

final Set<inapp.InAppWebView> _attached = Set.identity();

/// The system back gesture, as Android delivers it to the app.
Future<void> pressBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settleRealApp(tester);
}

/// A webview with no page in it: nothing to go back to, nothing loading,
/// and every other call answered with nothing.
class _FakeWebViewController implements inapp.InAppWebViewController {
  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> isLoading() async => false;

  // A completed Future<Null> passes for every Future<T?> the page awaits.
  // ignore: prefer_void_to_null
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isMethod ? Future<Null>.value() : null;
}
