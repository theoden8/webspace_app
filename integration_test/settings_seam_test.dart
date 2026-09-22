// The general guard on the seam BUG-014 is named after (caution 7).
//
// The Apple failure is reflective: `ISettings.parse` sets values behind
// `responds(to:)`, so a property the Objective-C runtime cannot see is skipped
// with no error. That is how the per-site proxy was never bound at all --
// `proxySettings` is typed `[String: Any?]?`, which has no ObjC
// representation, so the parser walked past it and every Dart-side test still
// passed. Android's `InAppWebViewSettings.java` parses with an explicit
// `switch`, so its failure is a field nobody wired rather than one the runtime
// could not see: different cause, identical symptom, same map, same channel.
// The Dart side logs what it *sent*, the native side acts on what it
// *parsed*, and nothing compared the two.
//
// This is that comparison: send each field with a value that is NOT the
// engine's default, ask the engine what it holds, fail naming any that did not
// survive. Every value here differs from a native default, because a field the
// parser skipped comes back AS its default and that is the only way to tell.
//
// WHAT THE READBACK CAN SEE IS NOT THE SAME EVERYWHERE, so each field carries
// the platforms where comparing it means something, and the run prints the
// ones it skipped with the reason (caution 8):
//
//   android   `getRealSettings` starts from `toMap()` (every parsed field) and
//             overwrites userAgent/javaScriptEnabled and friends from the live
//             `WebSettings`.
//   macos     `toMap()` is a `Mirror`, so Swift-only properties are in it --
//             `proxySettings` included. userAgent/javaScriptEnabled/
//             preferredContentMode come off the live WKWebView.
//   ios       `toMap()` is `class_copyPropertyList`, i.e. ObjC properties
//             only, so `proxySettings` is INVISIBLE there even when it was
//             applied. Comparing it on iOS would report a loss that is not
//             one (caution 14).
//   linux     `getRealSettings` does not start from `toMap()` at all; it
//             returns eight keys read off `WebKitSettings`. Only the live ones
//             are comparable there.
//
// THE CONTROL (caution 2). A readback alone would be satisfied by an engine
// that echoed the map it was handed, and then this file would pass while
// measuring nothing. So the user agent is also asserted at the effect level:
// the page's own `navigator.userAgent` must report the string we sent. No echo
// produces that. It is read first, and if it fails the comparison below is not
// evidence.
//
// WHY THE READBACK IS TRUSTWORTHY AT ALL, when caution 5 says a readback is
// not evidence: caution 5 is about `WKWebsiteDataStore.proxyConfigurations`,
// whose getter is a UI-process cache. `getSettings()` is a different call.

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';

/// One field's trip across the channel.
class _Field {
  const _Field(
    this.name, {
    required this.sent,
    required this.read,
    required this.comparable,
    required this.skipWhy,
    this.live = false,
  });

  final String name;
  final Object? sent;
  final Object? Function(inapp.InAppWebViewSettings s) read;

  /// Whether the engine's answer means anything on this host. False is not a
  /// pass: it is printed with [skipWhy] so a reader can tell a comparison
  /// that held from one that never ran.
  final bool Function() comparable;
  final String skipWhy;

  /// Read off the live native view rather than echoed from the parsed map.
  /// At least one of these has to be compared, or the file proves only that
  /// the engine can repeat itself.
  final bool live;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Every platform whose engine answers `getSettings()`. Windows and web have
  // no such engine here; everywhere else the comparison runs, on the subset of
  // fields that platform's readback can actually see.
  final applies = hostIsIOS || hostIsMacOS || hostIsAndroid || hostIsLinux;

  // Desktop-shaped so `isDesktopUserAgent` is true and the app sends
  // preferredContentMode = DESKTOP: a second field that is read off the live
  // view on Apple rather than echoed.
  const sentUserAgent =
      'Mozilla/5.0 (X11; CPU OS 0) WebspaceSeamProbe/1.0 (BUG-014 caution 7)';
  const siteId = 'settings-seam';
  const proxyAddress = '127.0.0.1:1080';

  var containers = false;
  WebViewController? controller;

  void log(String m) {
    // ignore: avoid_print
    print('[settings-seam] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    // Warms `ContainerNative.cachedSupported`, which is what the app reads
    // when it decides whether this site gets a container of its own.
    containers = await ContainerNative.instance.isSupported();
  });

  /// Whether this platform can answer, and what that decision rested on.
  /// Printed either way: a gate that can only skip is not a gate (caution 8),
  /// and on Android the container half of it depends on the emulator image's
  /// System WebView reporting MULTI_PROFILE.
  bool usable() {
    log('platform=${hostIsIOS ? "ios" : hostIsMacOS ? "macos" : hostIsAndroid ? "android" : hostIsLinux ? "linux" : "other"} '
        'applies=$applies containers=$containers '
        'proxySupported=${PlatformInfo.isProxySupported}');
    if (!applies) {
      markTestSkipped('no engine here answers getSettings()');
      return false;
    }
    return true;
  }

  Future<void> mount(
    WidgetTester tester, {
    required bool incognito,
    required bool javascriptEnabled,
  }) async {
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
                javascriptEnabled: javascriptEnabled,
                incognito: incognito,
                // Native default is true, so `false` is the value that can
                // tell a parsed field from a skipped one.
                thirdPartyCookiesEnabled: false,
                proxySettings: UserProxySettings(
                  type: ProxyType.SOCKS5,
                  address: proxyAddress,
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

  /// Compares [fields] against [live], printing every one either way, and
  /// fails naming those that did not survive.
  void compare(String label, inapp.InAppWebViewSettings live,
      List<_Field> fields) {
    final lost = <String>[];
    final compared = <_Field>[];
    for (final f in fields) {
      if (!f.comparable()) {
        log('$label ${f.name}: not compared here -- ${f.skipWhy}');
        continue;
      }
      final got = f.read(live);
      log('$label ${f.name}: sent=${f.sent} engine=$got'
          '${f.live ? " (live)" : ""}');
      compared.add(f);
      if (got != f.sent) {
        lost.add('${f.name} (sent ${f.sent}, engine holds $got)');
      }
    }

    expect(compared, isNotEmpty,
        reason: 'every field skipped itself on this host, so $label ran the '
            'app and asserted nothing (caution 8)');
    expect(compared.any((f) => f.live), isTrue,
        reason: 'nothing compared here was read off the live native view, so '
            '$label cannot tell a working engine from one echoing the map it '
            'was handed');
    expect(lost, isEmpty,
        reason: 'these per-site fields did not survive the platform channel. '
            'A field the Apple parser cannot see is skipped with no error, '
            'and one no Android switch arm names is dropped the same way '
            '(BUG-014 instances 1 and 2, caution 15): ${lost.join("; ")}');
  }

  testWidgets('every per-site field Dart sends survives the native seam',
      (tester) async {
    if (!usable()) return;
    await mount(tester, incognito: false, javascriptEnabled: true);
    expect(
        await waitReal(tester, () => controller != null,
            label: 'controller created'),
        isTrue,
        reason: 'no controller, so nothing was asked of the engine and no '
            'field below was measured');

    inapp.InAppWebViewSettings? live;
    String? liveNavigatorUa;
    await tester.runAsync(() async {
      live = await controller!.nativeController.getSettings();
      // The control. An engine that echoed our map would satisfy every
      // comparison below; only the page can report what the view really uses.
      final raw = await controller!.nativeController
          .evaluateJavascript(source: 'navigator.userAgent');
      liveNavigatorUa = raw?.toString();
    });

    expect(live, isNotNull,
        reason: 'the engine reported no settings at all, so this file '
            'measured nothing');
    log('navigator.userAgent=$liveNavigatorUa');
    expect(liveNavigatorUa, contains('WebspaceSeamProbe'),
        reason: 'the page does not report the user agent this test sent, so '
            'the comparison below cannot be trusted to reflect the live view '
            'rather than the map the engine was handed (BUG-014 caution 2)');

    compare('persistent', live!, [
      _Field('userAgent',
          sent: sentUserAgent,
          read: (s) => s.userAgent,
          live: true,
          comparable: () => true,
          skipWhy: ''),
      _Field('preferredContentMode',
          sent: inapp.UserPreferredContentMode.DESKTOP,
          read: (s) => s.preferredContentMode,
          live: hostIsIOS || hostIsMacOS,
          comparable: () => !hostIsLinux,
          skipWhy: "Linux's getRealSettings returns only the eight keys it "
              'reads off WebKitSettings, and this is not one'),
      _Field('containerId',
          sent: 'ws-$siteId',
          read: (s) => s.containerId,
          comparable: () => containers && !hostIsLinux,
          skipWhy: containers
              ? "Linux's getRealSettings does not report it"
              : 'this engine reports no container support, so the app binds '
                  'no container and there is no value to lose (on Android '
                  'this means the image ships a System WebView without '
                  'MULTI_PROFILE)'),
      _Field('thirdPartyCookiesEnabled',
          sent: false,
          read: (s) => s.thirdPartyCookiesEnabled,
          comparable: () => hostIsAndroid,
          skipWhy: 'the field exists only in the Android settings class'),
      _Field('proxySettings.proxyRules.isNotEmpty',
          sent: true,
          read: (s) => s.proxySettings?.proxyRules.isNotEmpty ?? false,
          comparable: () => hostIsMacOS,
          skipWhy: hostIsIOS
              ? "iOS builds its readback from class_copyPropertyList, and "
                  'proxySettings is a Swift-only type with no ObjC property, '
                  'so it is invisible there even when applied (caution 14)'
              : hostIsAndroid
                  ? 'Android has no per-WebView proxy: the rule is process-'
                      'wide through ProxyController, which has no readback'
                  : "Linux binds the proxy on the container's network "
                      'session and does not report it back',
          live: false),
    ]);
  });

  testWidgets('an incognito site with JS off crosses the same seam',
      (tester) async {
    // Two more fields, and they cannot ride the mount above: incognito is
    // what the app checks before binding a container on Apple, and JS off
    // would take the control with it. The control the process needed was
    // read there, in this same app run.
    if (!usable()) return;
    await mount(tester, incognito: true, javascriptEnabled: false);
    expect(
        await waitReal(tester, () => controller != null,
            label: 'controller created'),
        isTrue);

    inapp.InAppWebViewSettings? live;
    await tester.runAsync(() async {
      live = await controller!.nativeController.getSettings();
    });
    expect(live, isNotNull);

    compare('incognito', live!, [
      _Field('javaScriptEnabled',
          sent: false,
          read: (s) => s.javaScriptEnabled,
          live: true,
          comparable: () => true,
          skipWhy: ''),
      _Field('incognito',
          sent: true,
          read: (s) => s.incognito,
          comparable: () => !hostIsLinux,
          skipWhy: "Linux's getRealSettings does not report it"),
      _Field('containerId',
          // Android has no ephemeral profile, so it binds a named one even
          // under incognito (ARCH-006). The others short-circuit to an
          // ephemeral store, which is a session of its own and needs no name.
          sent: 'ws-$siteId',
          read: (s) => s.containerId,
          comparable: () => containers && hostIsAndroid,
          skipWhy: hostIsAndroid
              ? 'this image reports no MULTI_PROFILE, so the app binds no '
                  'container here'
              : 'an incognito site gets no named container on this platform, '
                  'so the expected value is null -- which a field the parser '
                  'dropped would also produce'),
    ]);
  });
}
