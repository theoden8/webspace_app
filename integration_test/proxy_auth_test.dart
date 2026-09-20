// Per-site proxy with embedded authentication credentials (PROXY-001 +
// PWD-005), and what happens where those credentials cannot be delivered
// (PROXY-020).
//
// Two seeded sites, activated in order:
//
//   Proxy Site B -- no credentials. Its address must reach the platform
//     `ProxyController`. This is the positive control: without it, a
//     regression that stopped delivering any proxy at all on a platform
//     would satisfy every assertion the credentialed site makes.
//   Proxy Site -- username + password, the password read back out of
//     `flutter_secure_storage` because PWD-005 forbids `toJson` carrying
//     it. Where the platform can carry credentials the URL must embed
//     them; on iOS/macOS it cannot, and the contract is that the app
//     refuses rather than connecting unauthenticated.
//
// The `flutter_inappwebview_proxycontroller` channel is mocked so the exact
// `setProxyOverride` arguments are capturable without a live network stack;
// it is the same channel on every platform. Activating a site triggers
// `setController` -> `_applyProxySettings` -> `ProxyController`.

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'secure_storage_fake.dart';

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
    // macOS CI is ad-hoc signed and can't use the keychain (-34018); fall
    // back to an in-memory store so the password seed/hydration round-trips.
    // No-op where the real keychain works (Linux pass-secret-service).
    await installInMemoryKeychainIfUnavailable();

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
    final plainSite = WebViewModel(
      siteId: 'proxy-2',
      initUrl: 'http://192.0.2.2/',
      name: 'Proxy Site B',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '198.51.100.2:8080',
      ),
    );
    // Credential-free site first: the app activates index 0 at startup, so
    // the positive control below costs no drawer interaction and the one
    // that remains is the last thing the test does.
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(plainSite.toJson()),
        jsonEncode(site.toJson()),
      ],
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

  testWidgets('per-site proxy delivery, and refusal where it cannot carry '
      'credentials', (tester) async {
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

    /// Drive the engine long enough for a WebView to mount and fire
    /// onControllerCreated. pumpAndSettle deadlocks on a live WebView, so
    /// pump fixed slices instead.
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    /// Open the drawer and activate [name].
    ///
    /// Tapping the already-active webspace tile is the same-id branch in
    /// `_selectWebspace`, which opens the drawer. Called once, and last:
    /// re-opening the drawer after a site has been activated does not find
    /// the tile again.
    Future<void> activate(String name) async {
      final allTile = find.byKey(const ValueKey(kAllWebspaceId));
      expect(allTile, findsOneWidget);
      await tester.tap(allTile);
      await tester.pumpAndSettle(const Duration(seconds: 5));

      final siteTile = find.text(name);
      if (siteTile.evaluate().isEmpty) {
        dumpTexts('drawer open for $name');
      }
      expect(siteTile, findsOneWidget,
          reason: 'seeded site "$name" should appear in the drawer');

      await tester.tap(siteTile);
      await settle();
    }

    /// Every `setProxyOverride` whose rule URL mentions [needle].
    List<String> overrideUrlsFor(String needle) {
      final urls = <String>[];
      for (final call in capturedCalls) {
        if (call.method != 'setProxyOverride') continue;
        final args = call.arguments as Map?;
        final settings = (args?['settings'] as Map?)?.cast<String, dynamic>();
        final rules = settings?['proxyRules'] as List?;
        if (rules == null || rules.isEmpty) continue;
        final url = (rules.first as Map)['url'] as String?;
        if (url != null && url.contains(needle)) urls.add(url);
      }
      return urls;
    }

    /// The per-site proxy baked into the mounted WebView's
    /// `initialSettings`, or null when the platform did not use that path.
    List<inapp.ProxyRule>? mountedWebViewRules() {
      final webviewFinder = find.byType(inapp.InAppWebView);
      expect(webviewFinder, findsWidgets,
          reason: 'activating a site should mount its WebView');
      return tester
          .widget<inapp.InAppWebView>(webviewFinder.first)
          .platform
          .params
          .initialSettings
          ?.proxySettings
          ?.proxyRules;
    }

    // Positive control, on the site the app activated at startup. A proxy
    // with nothing to authenticate reaches the platform on every tier this
    // file runs on, including the Apple one where the credentialed case
    // below is refused.
    await settle();
    final plain = overrideUrlsFor('198.51.100.2:8080');
    if (plain.isEmpty) {
      // ignore: avoid_print
      print('captured channel calls: '
          '${capturedCalls.map((c) => c.method).toList()}');
    }
    expect(plain, isNotEmpty,
        reason: 'a credential-free per-site proxy should reach '
            'ProxyController.setProxyOverride');
    expect(plain.last, startsWith('http://'),
        reason: 'HTTP proxy type should produce http:// scheme');

    await activate('Proxy Site');

    if (Platform.isIOS || Platform.isMacOS) {
      // PROXY-020. `ProxyRule.toProxyConfiguration` reads only host and
      // port off the rule URL, so inline userinfo is dropped, and
      // `applyCredential` never puts a Proxy-Authorization on the wire.
      // Connecting anyway would send the request unauthenticated, so the
      // app refuses: nothing reaches the platform for this site.
      expect(overrideUrlsFor('198.51.100.1'), isEmpty,
          reason: 'a credentialed proxy must not reach the platform on a '
              'tier that cannot authenticate to it');
      expect(overrideUrlsFor('puser'), isEmpty);
      expect(overrideUrlsFor('sekret-pass'), isEmpty,
          reason: 'the password must never reach a proxy rule that would '
              'drop it');
      // And not through the per-WebView field either: that binding is
      // developer-mode only, and this tier runs with it off.
      expect(mountedWebViewRules(), isNull,
          reason: 'the per-store binding is developer-mode only, so the '
              'WebView carries no proxySettings here');
    } else {
      // Android/Linux: credentials ride the proxy URL through
      // ProxyController.setProxyOverride.
      final creds = overrideUrlsFor('198.51.100.1:8080');
      if (creds.isEmpty) {
        // ignore: avoid_print
        print('captured channel calls: '
            '${capturedCalls.map((c) => c.method).toList()}');
      }
      expect(creds, isNotEmpty,
          reason: 'setProxyOverride should fire after site activation');
      final url = creds.last;
      expect(url, startsWith('http://'),
          reason: 'HTTP proxy type should produce http:// scheme');
      expect(url, contains('puser'),
          reason: 'proxy URL should embed the per-site username');
      expect(url, contains('sekret-pass'),
          reason: 'proxy URL should embed the password from secure storage');
    }
  });
}
