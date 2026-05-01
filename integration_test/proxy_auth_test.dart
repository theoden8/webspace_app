// Per-site proxy with embedded authentication credentials (PROXY-001 + PWD-005).
//
// Pre-seeds a single site with an HTTP proxy whose username + password
// must materialise in the URL passed to the platform `ProxyController`.
// PWD-005 forbids serialising the password through `toJson`, so the
// password is written into `flutter_secure_storage` directly (the same
// libsecret/pass_secret_service path used in production on Linux).
//
// The Linux `flutter_inappwebview_proxycontroller` channel is mocked so
// the test can capture the exact `setProxyOverride` arguments without
// depending on a live WPE WebKit network stack. Activating the site
// triggers `setController` -> `_applyProxySettings` ->
// `ProxyController.setProxyOverride`, which routes through that channel.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const proxyChannel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_proxycontroller',
  );
  const secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final List<MethodCall> capturedCalls = <MethodCall>[];

  setUpAll(() async {
    isDemoMode = true;

    final site = WebViewModel(
      siteId: 'proxy-1',
      // RFC 5737 reserved test address; the WebView won't connect, but
      // it doesn't need to — the assertion is on the captured proxy
      // method call, not on page load.
      initUrl: 'http://192.0.2.1/',
      name: 'Proxy Site',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '198.51.100.1:8080',
        username: 'puser',
      ),
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(site.toJson())],
    });

    // PWD-005: password lives in secure storage, never in JSON. Seed it
    // through the real platform channel so the app's hydration path
    // (loadAll inside _loadWebViewModels) finds it.
    await secure.write(
      key: 'proxy_passwords',
      value: jsonEncode({'proxy-1': 'sekret-pass'}),
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, (call) async {
      capturedCalls.add(call);
      return null;
    });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, null);
    await secure.delete(key: 'proxy_passwords');
  });

  testWidgets('per-site proxy override carries embedded credentials',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    void dumpTexts(String label) {
      // ignore: avoid_print
      print('$label texts: '
          '${find.byType(Text).evaluate().map((e) {
        final w = e.widget;
        return w is Text ? (w.data ?? '?') : '?';
      }).take(40).toList()}');
    }

    // Open the drawer via the All-webspace tile (the same-id branch in
    // _selectWebspace calls openDrawer when tapping the already-active
    // webspace).
    final allTile = find.byKey(const ValueKey(kAllWebspaceId));
    expect(allTile, findsOneWidget);
    await tester.tap(allTile);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final siteTile = find.text('Proxy Site');
    if (siteTile.evaluate().isEmpty) {
      dumpTexts('drawer open');
    }
    expect(siteTile, findsOneWidget,
        reason: 'seeded proxy site should appear in the drawer');

    // Activating the site triggers WebView creation -> onControllerCreated
    // -> setController -> _applyProxySettings -> ProxyController.setProxyOverride.
    await tester.tap(siteTile);
    // Drive the engine for long enough that the WebView fully mounts and
    // its controller fires onControllerCreated. pumpAndSettle deadlocks
    // on a live WebView, so pump in fixed slices instead.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    final overrides =
        capturedCalls.where((c) => c.method == 'setProxyOverride').toList();
    if (overrides.isEmpty) {
      // ignore: avoid_print
      print('captured channel calls: '
          '${capturedCalls.map((c) => c.method).toList()}');
    }
    expect(overrides, isNotEmpty,
        reason: 'setProxyOverride should fire after site activation');

    final args = overrides.last.arguments as Map?;
    final settings = (args?['settings'] as Map?)?.cast<String, dynamic>();
    final rules = (settings?['proxyRules'] as List?);
    expect(rules, isNotNull);
    final url = (rules!.first as Map)['url'] as String?;
    expect(url, isNotNull, reason: 'proxy rule should carry a url');
    expect(url, startsWith('http://'),
        reason: 'HTTP proxy type should produce http:// scheme');
    expect(url, contains('198.51.100.1:8080'),
        reason: 'proxy URL should carry the configured host:port');
    expect(url, contains('puser'),
        reason: 'proxy URL should embed the per-site username');
    expect(url, contains('sekret-pass'),
        reason: 'proxy URL should embed the password loaded from secure storage');
  });
}
