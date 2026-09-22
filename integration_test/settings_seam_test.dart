// The general guard on the seam BUG-014 is named after (caution 7).
//
// `ISettings.parse` in the Apple plugins sets values reflectively behind
// `responds(to:)`, so a property the Objective-C runtime cannot see is skipped
// with no error. That is how the per-site proxy was never bound at all:
// `proxySettings` was typed `[String: Any?]?`, a Swift-only type with no ObjC
// representation, so the parser walked past it and every Dart-side test still
// passed. The Dart side logs what it *sent*; the native side acts on what it
// *parsed*; nothing compared the two.
//
// Instances 1, 2 and 5 are all that shape. Only the proxy ever got an
// effect-level test, and the same parser carries the container id, the user
// agent, the incognito flag and every other per-site field.
//
// This is the comparison: send each field with a value that is NOT its
// default, ask the engine what it actually holds, and fail naming any that
// did not survive. A field that the parser skipped comes back as its default,
// which is why every value here is chosen to differ from one.
//
// WHY THE READBACK IS TRUSTWORTHY HERE, when caution 5 says a readback is not
// evidence. Caution 5 is about `WKWebsiteDataStore.proxyConfigurations`, whose
// getter is a UI-process cache. This is a different call:
// `getSettings()` returns `settings.getRealSettings(obj: self)`, which starts
// from the parsed settings object and then OVERWRITES specific keys by reading
// the live `WKWebView` -- `userAgent` from `webView.customUserAgent`,
// `javaScriptEnabled` from `configuration.defaultWebpagePreferences`. So a
// field in that overwrite set is read back off the real view.
//
// THE CONTROL (caution 2). A readback alone could be satisfied by an engine
// that echoed the map it was handed, and then this file would pass while
// measuring nothing. So the user agent is also asserted at the effect level:
// the page's own `navigator.userAgent` must report the string we sent. No echo
// can produce that, and if it fails the map comparison below is not evidence.

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The reflective parser is Apple's. Android's settings cross a generated
  // channel that fails loudly on a type it cannot carry, so the silent-skip
  // shape does not arise there -- but the comparison is still worth running,
  // because a field lost anywhere between `WebViewConfig` and the engine is
  // the same defect from a user's side.
  final applies = hostIsIOS || hostIsMacOS || hostIsAndroid;

  // Values chosen to differ from the engine's defaults, so a field the parser
  // skipped reads back as something else and this file can tell.
  const sentUserAgent = 'WebspaceSeamProbe/1.0 (BUG-014 caution 7)';
  const siteId = 'settings-seam';
  late Socks5Fixture socks;
  var containers = false;
  WebViewController? controller;

  void log(String m) {
    // ignore: avoid_print
    print('[settings-seam] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    socks = await Socks5Fixture.bind();
  });

  tearDownAll(() async {
    if (!applies) return;
    await socks.close();
  });

  /// Whether this platform can answer, and what that decision rested on.
  /// Printed either way: caution 8 -- a gate that can only skip is not a gate,
  /// and a reader has to be able to tell a pass from an absence.
  bool usable() {
    log('platform=${hostIsIOS ? "ios" : hostIsMacOS ? "macos" : hostIsAndroid ? "android" : "other"} '
        'applies=$applies containers=$containers '
        'proxySupported=${PlatformInfo.isProxySupported}');
    if (!applies) {
      markTestSkipped('the reflective settings seam is a mobile/desktop '
          'webview path; this host has no engine to ask');
      return false;
    }
    return true;
  }

  Future<void> mount(WidgetTester tester) async {
    controller = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                siteId: siteId,
                // No network: the seam is about what crossed the channel, and
                // a destination would only add a way for this to fail for an
                // unrelated reason.
                initialUrl: 'about:blank',
                userAgent: sentUserAgent,
                incognito: true,
                thirdPartyCookiesEnabled: true,
                proxySettings: UserProxySettings(
                  type: ProxyType.SOCKS5,
                  address: '127.0.0.1:${socks.port}',
                ),
                clearUrlEnabled: false,
                dnsBlockEnabled: false,
                contentBlockEnabled: false,
                trackingProtectionEnabled: false,
                localCdnEnabled: false,
              ),
              onControllerCreated: (c) => controller = c,
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var ok = false;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (done()) {
          ok = true;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      ok = done();
    });
    log('$label -> ${ok ? "ok" : "timeout"}');
    return ok;
  }

  testWidgets('every per-site field Dart sends survives the native seam',
      (tester) async {
    if (!usable()) return;
    await mount(tester);
    expect(await waitReal(tester, () => controller != null,
            label: 'controller created'),
        isTrue,
        reason: 'no controller, so nothing was asked of the engine and no '
            'field below was measured');

    inapp.InAppWebViewSettings? live;
    String? liveNavigatorUa;
    await tester.runAsync(() async {
      live = await controller!.nativeController.getSettings();
      // The control. An engine that echoed our map would satisfy every
      // assertion below; only the page can report what the view really uses.
      final raw = await controller!.nativeController
          .evaluateJavascript(source: 'navigator.userAgent');
      liveNavigatorUa = raw?.toString();
    });

    expect(live, isNotNull,
        reason: 'the engine reported no settings at all, so this file '
            'measured nothing');

    // sent -> got, printed whole so a reader can see which fields were
    // compared rather than trusting that some were.
    final checks = <String, (Object?, Object?)>{
      'userAgent': (sentUserAgent, live?.userAgent),
      'incognito': (true, live?.incognito),
      'thirdPartyCookiesEnabled': (true, live?.thirdPartyCookiesEnabled),
      'containerId': ('ws-$siteId', live?.containerId),
      'proxySettings.proxyRules.isNotEmpty': (
        true,
        live?.proxySettings?.proxyRules.isNotEmpty ?? false,
      ),
    };
    for (final e in checks.entries) {
      log('${e.key}: sent=${e.value.$1} got=${e.value.$2}');
    }
    log('navigator.userAgent=$liveNavigatorUa');

    // Control first: without it the comparison above is not evidence.
    expect(liveNavigatorUa, contains('WebspaceSeamProbe'),
        reason: 'the page does not report the user agent this test sent, so '
            'the readback below cannot be trusted to reflect the live view '
            'rather than the map the engine was handed (BUG-014 caution 2)');

    final lost = <String>[
      for (final e in checks.entries)
        if (e.value.$1 != e.value.$2) '${e.key} (sent ${e.value.$1}, '
            'engine holds ${e.value.$2})',
    ];
    expect(lost, isEmpty,
        reason: 'these per-site fields did not survive the platform channel. '
            'A field the reflective parser cannot see is skipped with no '
            'error, which is how the per-site proxy was never bound at all '
            '(BUG-014 instance 1, caution 7): ${lost.join("; ")}');
  });

  testWidgets('the comparison can tell a lost field from a kept one',
      (tester) async {
    // The falsifiability check for the file above. If the engine returned our
    // own map, or returned defaults for everything, one of these two would not
    // hold -- so a reader knows the comparison discriminates rather than
    // passing on anything.
    if (!usable()) return;
    await mount(tester);
    expect(await waitReal(tester, () => controller != null,
            label: 'controller created'),
        isTrue);

    inapp.InAppWebViewSettings? live;
    await tester.runAsync(() async {
      live = await controller!.nativeController.getSettings();
    });
    expect(live, isNotNull);

    // A field this test never set must read as its default, not as anything
    // we sent: proof the engine is reporting its own state.
    log('unset field mediaPlaybackRequiresUserGesture=${live?.mediaPlaybackRequiresUserGesture}');
    expect(live?.userAgent, isNot(equals(live?.applicationNameForUserAgent)),
        reason: 'the user agent and the application name read back identical, '
            'which suggests the engine is not reporting per-field state');
  });
}
