// The per-site proxy is actually bound to the engine (LEAK-003, PROXY-011).
//
// Everything else about the per-site proxy is decided in Dart and tested
// there: which proxy a site resolves to, whether a Tor site waits for the
// runtime, whether a malformed address fails closed. None of that can see
// the one thing that matters -- whether the engine received the proxy at
// all. On iOS and macOS it is delivered as one field on
// `InAppWebViewSettings`, parsed natively, and a parse that drops it is
// silent: the Dart side reports a proxy, the page loads over the device IP,
// and only the site being visited can tell the difference.
//
// That is not hypothetical. `proxySettings` was typed `[String: Any?]?`,
// which Objective-C cannot represent, so the plugin's reflective settings
// parser skipped it and no per-site proxy was ever applied on either Apple
// platform.
//
// Two rules this file learned the hard way, both of which made it pass while
// no proxy was bound at all:
//
//  * The origin must not be on loopback. Apple never proxies `127.0.0.1`,
//    so a loopback fixture loads directly whichever way the binding went.
//  * A second webview for the same site needs its own subtree key. Pumping
//    the same widget position again updates the existing platform view
//    instead of building a new one, so the second load is never issued and
//    "the origin was not reached" holds for free.
//
// So the assertions here are positive wherever they can be: the fixture
// SOCKS5 server must have been asked for the origin. A negative ("the
// origin was not reached") is satisfied by any broken load, and every way
// this file has been wrong so far broke the load.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'fixture_server.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  late HttpServer server;
  late String originHost;
  late int port;
  late int deadPort;
  late Socks5Fixture socks;
  InternetAddress? routable;
  final requests = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-binding] $m');
  }

  var containers = false;

  /// Where the plugin writes its account of what it bound. It writes to a
  /// file rather than stdout because `flutter test` does not capture the
  /// host app's, and the test runs inside that app so both see the same
  /// directory.
  final trace =
      File('${Directory.systemTemp.path}/webspace-container-store.log');

  setUpAll(() async {
    // The tier runs one file per app process into the same path, so without
    // this the trace carries entries from earlier files' processes -- which
    // is how the last run's trace opened with webviews this file never
    // built.
    if (trace.existsSync()) trace.deleteSync();
    await PlatformInfo.initialize();
    // The app resolves this at startup and every proxied site it builds has
    // a container of its own as a result. Without it here each WebView got
    // `WKWebsiteDataStore.default()` instead -- a process singleton that the
    // first load puts into service -- so this file was measuring a store
    // shape the app never uses.
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    port = server.port;
    originHost = (routable ?? InternetAddress.loopbackIPv4).address;
    listenFixture(server, (req) async {
      requests.add(req.uri.path);
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>origin</p></body></html>');
      await res.close();
    });
    socks = await Socks5Fixture.bind();
    // Claimed, then released: a connection there is refused rather than
    // filtered, so a bound proxy fails fast instead of timing out.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    deadPort = probe.port;
    await probe.close();
    log('origin on $originHost:$port, socks on ${socks.port}, '
        'dead proxy on $deadPort, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');

  });

  /// Which scenarios saw the proxy, in one line at the end of the file's
  /// output. The tier re-prints only the last 60 lines of a failing file, and
  /// twice now the scenario that decided the diagnosis was further back than
  /// that -- leaving the verdict to be inferred from a pass/fail count.
  final verdict = <String>[];

  tearDownAll(() async {
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    if (trace.existsSync()) {
      for (final line in trace.readAsLinesSync()) {
        log('native: $line');
      }
      trace.deleteSync();
    } else {
      log('native: no container-store trace was written');
    }
    await socks.close();
    await server.close(force: true);
  });

  setUp(() {
    requests.clear();
    socks.targets.clear();
  });

  /// Skips off-Apple, and fails rather than skips when the environment
  /// cannot host the assertion. A silent skip is how this file spent its
  /// whole life reporting green over an unbound proxy.
  bool usable() {
    if (!applies) {
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return false;
    }
    expect(
      routable,
      isNotNull,
      reason: 'no non-loopback IPv4 on this machine, and Apple never sends a '
          'loopback destination through a proxy, so nothing here could '
          'distinguish a bound proxy from an unbound one',
    );
    return true;
  }

  var generation = 0;
  WebViewController? controller;
  WebViewController? deferred;

  Future<void> mount(
    WidgetTester tester, {
    required String? siteId,
    required String path,
    UserProxySettings? proxySettings,
  }) async {
    // A fresh key per mount. Without it the second mount updates the
    // existing InAppWebView element, which keeps the platform view it
    // already had and never issues the new initial load.
    final key = ValueKey('webview-${generation++}');
    controller = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            child: KeyedSubtree(
              key: key,
              child: WebViewFactory.createWebView(
                config: WebViewConfig(
                  siteId: siteId,
                  initialUrl: 'http://$originHost:$port$path',
                  proxySettings: proxySettings,
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
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  UserProxySettings liveProxy() => UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:${socks.port}',
      );

  UserProxySettings refusedProxy() => UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:$deadPort',
      );

  /// Wall-clock wait: a live compositing platform view blocks `pump()`.
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

  testWidgets('every webview built in the first frame uses its proxy',
      (tester) async {
    // The rule, and the only arrangement that satisfies it.
    //
    // Three runs with different arrangements agree (BUG-014 attempts 19-22):
    // WebViews created in the process's first frame all bind their proxy;
    // a WebView created in any later turn never does, whatever was done to
    // its data store beforehand. Arming the store early is not what matters
    // -- attempt 20 armed six stores in one call before anything touched the
    // network and changed nothing. It is when the WKWebView is built.
    //
    // So this frame carries every proxied site the file uses: two on a live
    // SOCKS5 fixture, one on a closed port, and one with nothing to load yet.
    // The dead-proxy pane is a control in the positive direction -- a bound
    // proxy that refuses cannot reach the origin, and a load that arrives
    // there says the binding did not happen.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    Widget pane(String siteId, String url, UserProxySettings proxy) => SizedBox(
          width: 320,
          height: 160,
          child: WebViewFactory.createWebView(
            config: WebViewConfig(
              siteId: siteId,
              initialUrl: url,
              proxySettings: proxy,
              clearUrlEnabled: false,
              dnsBlockEnabled: false,
              contentBlockEnabled: false,
              trackingProtectionEnabled: false,
              localCdnEnabled: false,
            ),
            onControllerCreated: (c) {
              if (siteId == 'proxy-binding-deferred') deferred = c;
            },
          ),
        );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          KeyedSubtree(
            key: const ValueKey('pair-a'),
            child: pane('proxy-binding-pair-a',
                'http://$originHost:$port/pair-a', liveProxy()),
          ),
          KeyedSubtree(
            key: const ValueKey('pair-b'),
            child: pane('proxy-binding-pair-b',
                'http://$originHost:$port/pair-b', liveProxy()),
          ),
          KeyedSubtree(
            key: const ValueKey('refused'),
            child: pane('proxy-binding-refused',
                'http://$originHost:$port/refused', refusedProxy()),
          ),
          // Built here, given nothing to fetch. Whether a WebView has to
          // *load* in the first frame to bind, or only exist, decides what
          // the app fix costs: creating one empty WebView per proxied site
          // at startup, or making every proxied site fetch its page at
          // launch whether the user opens it or not.
          KeyedSubtree(
            key: const ValueKey('deferred'),
            child:
                pane('proxy-binding-deferred', 'about:blank', liveProxy()),
          ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    final both = await waitReal(
      tester,
      () => socks.targets.length >= 2,
      label: 'two proxied sites built in the first frame',
      timeout: const Duration(seconds: 25),
    );
    final direct = [
      if (requests.contains('/pair-a')) 'a',
      if (requests.contains('/pair-b')) 'b',
    ];
    verdict.add('pair=${socks.targets.length} of 2 proxied, '
        'direct=${direct.isEmpty ? "none" : direct.join("+")}');
    expect(
      socks.targets.length + direct.length,
      2,
      reason: 'the two panes issued ${socks.targets.length + direct.length} '
          'loads between them, not 2, so this measured the mount rather than '
          'the binding',
    );
    expect(both, isTrue,
        reason: 'a proxied webview built in the process\'s first frame did '
            'not use its proxy, so nothing in this file holds');

    // The refused pane shares the frame, so it is bound too; a bound proxy
    // on a closed port cannot reach anything.
    await waitReal(tester, () => requests.contains('/refused'),
        label: 'refused load (must not arrive)',
        timeout: const Duration(seconds: 10));
    verdict.add(
        'refused=${requests.contains('/refused') ? "DIRECT" : "failed closed"}');
    expect(
      requests,
      isNot(contains('/refused')),
      reason: 'a site whose proxy refuses connections reached the origin '
          'anyway, which a bound proxy cannot do',
    );
  });

  testWidgets('a webview built empty in the first frame binds for a later load',
      (tester) async {
    // Built in the frame above with `about:blank`, navigated now. If the
    // binding survives, the app fix is cheap: create one empty WebView per
    // proxied site at startup and let lazy loading carry on as it does. If
    // it does not, binding needs a real load in the first frame, and every
    // proxied site would have to fetch its page at launch.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    expect(await waitReal(tester, () => deferred != null,
            label: 'deferred controller created'),
        isTrue);
    await tester.runAsync(() async {
      await deferred!.nativeController.loadUrl(
        urlRequest: inapp.URLRequest(
          url: inapp.WebUri('http://$originHost:$port/deferred'),
        ),
      );
    });
    final used = await waitReal(
        tester, () => socks.targets.any((t) => t == '$originHost:$port'),
        label: 'deferred load through the proxy');
    final arrivedDirect = requests.contains('/deferred');
    verdict.add('deferred=${used && !arrivedDirect ? "proxied" : "DIRECT"}');
    expect(
      arrivedDirect,
      isFalse,
      reason: 'a webview built in the first frame but navigated later went '
          'direct, so existing in that frame is not enough and binding needs '
          'a load in it',
    );
  });

  testWidgets('the harness can see a load reach the origin', (tester) async {
    // The control. Without it, the assertions above pass for any reason a
    // page fails to load, which is most of them.
    if (!usable()) return;
    await mount(tester, siteId: 'proxy-binding-control', path: '/control');
    expect(
      await waitReal(tester, () => requests.contains('/control'),
          label: 'direct load'),
      isTrue,
      reason: 'an unproxied site never reached the fixture origin, so this '
          'file cannot tell a bound proxy from a broken harness',
    );
  });

  testWidgets('the engine received the proxy Dart sent it', (tester) async {
    // The original instance of this bug: `proxySettings` was typed
    // `[String: Any?]?`, which Objective-C cannot represent, so the plugin's
    // reflective settings parser skipped it and no per-site proxy was ever
    // applied on either Apple platform. Nothing failed.
    //
    // `getSettings()` asks the engine what it actually holds, which splits
    // the seam the load-level scenarios can only see the far side of: a null
    // here means the field never crossed the channel, non-null means it
    // crossed and was not applied. Those are different bugs.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      siteId: 'proxy-binding-seam',
      path: '/seam',
      proxySettings: liveProxy(),
    );
    expect(
        await waitReal(tester, () => controller != null,
            label: 'controller created'),
        isTrue);
    inapp.InAppWebViewSettings? live;
    await tester.runAsync(() async {
      live = await controller!.nativeController.getSettings();
    });
    log('native settings: proxySettings=${live?.proxySettings}');
    expect(live, isNotNull, reason: 'the engine reported no settings at all');
    expect(
      live?.proxySettings?.proxyRules,
      isNotEmpty,
      reason: 'the engine holds no proxy: the field did not survive the '
          'platform channel, so nothing downstream could have applied it',
    );
  });

  testWidgets('a webview built after the first frame', (tester) async {
    // The case no arrangement reaches, named rather than left to be
    // rediscovered.
    //
    // A WebView created in any turn after the process's first never binds
    // its proxy: not with its store armed beforehand (attempt 20), not with
    // a process-wide override, not on a fresh store, not on a rebuilt one.
    // So a site opened later in a session, a site whose proxy changes, an
    // archive unlocked mid-session and a Tor runtime that reports its port
    // after bootstrap all miss it, and Apple's public API offers no way back.
    //
    // Skipped rather than asserted either way: asserting the desired
    // behaviour leaves the tier permanently red, and asserting the actual
    // behaviour would be a test whose passing means a leak.
    if (!usable()) return;
    markTestSkipped(
      'a webview built after the first frame cannot bind a proxy on '
      'iOS/macOS; see docs/bugs/014 gap 4. Making the app build every '
      'proxied site in the first frame, and fail closed for the sites it '
      'cannot, is the follow-up.',
    );
    verdict.add('later-frame=not attempted (BUG-014 gap 4)');
  });
}
