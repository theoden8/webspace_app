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
  // Separate origins on separate ports: the fixture records CONNECT by
  // `host:port`, so one origin per navigation is what makes a recorded
  // CONNECT attributable. A second load to the *same* origin can also reuse
  // the first connection, which would look like no proxy was asked at all.
  late HttpServer deferredOrigin;
  late HttpServer factoryOrigin;
  late HttpServer persistOrigin;
  late String originHost;
  late int port;
  late int deferredPort;
  late int factoryPort;
  late int persistPort;
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
    persistOrigin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    persistPort = persistOrigin.port;
    listenFixture(persistOrigin, (req) async {
      requests.add('persist:${req.uri.path}');
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>persist</p></body></html>');
      await res.close();
    });
    listenFixture(server, (req) async {
      requests.add(req.uri.path);
      final res = req.response..headers.contentType = ContentType.html;
      // `/pair-a` navigates itself away after a moment. `persist` has to be
      // measured on a navigation the *page* issues, not one Dart issues
      // through the controller: those are different code paths in WebKit,
      // and a user only ever produces the first kind.
      if (req.uri.path == '/pair-a') {
        res.write('<!doctype html><html><body><p>origin</p><script>'
            'setTimeout(function(){'
            "location.href='http://$originHost:$persistPort/p';"
            '},5000);</script></body></html>');
      } else {
        res.write('<!doctype html><html><body><p>origin</p></body></html>');
      }
      await res.close();
    });
    factoryOrigin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    factoryPort = factoryOrigin.port;
    listenFixture(factoryOrigin, (req) async {
      requests.add('factory:${req.uri.path}');
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>factory</p></body></html>');
      await res.close();
    });
    deferredOrigin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    deferredPort = deferredOrigin.port;
    listenFixture(deferredOrigin, (req) async {
      requests.add('deferred:${req.uri.path}');
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>deferred</p></body></html>');
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
    await deferredOrigin.close(force: true);
    await factoryOrigin.close(force: true);
    await persistOrigin.close(force: true);
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

  /// One run of this file costs an hour, and a scenario costs nothing. So
  /// the factors get measured together rather than one per run: what the
  /// rule is keyed to, whether a webview must load or only exist, whether a
  /// binding survives navigation, and whether "first frame" or "any frame
  /// with more than one webview" is the boundary. Four of the last five
  /// runs each moved one variable, which is how attempt 20 came to be built
  /// on a reading that one extra scenario would have refuted.
  testWidgets('the first frame: what binds, and what a binding survives',
      (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    WebViewController? paneB;
    inapp.InAppWebViewController? raw;
    Widget pane(String siteId, String url, UserProxySettings proxy) => SizedBox(
          width: 320,
          height: 120,
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
              if (siteId == 'proxy-binding-pair-b') paneB = c;
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
          // Straight from the plugin: no `WebViewFactory`, so no
          // `shouldOverrideUrlLoading`, no universal-link bypass, no
          // per-site policy. Its second navigation is the only one in this
          // file that is a plain WebKit navigation, which is what decides
          // whether the leak is the platform's or this app's.
          //
          // It has to be in THIS frame. Built in any later one it cannot
          // bind at all, and the scenario would measure construction
          // instead of persistence -- which is exactly how the previous
          // run's `raw-first=DIRECT` came about.
          SizedBox(
            width: 320,
            height: 120,
            child: inapp.InAppWebView(
              key: const ValueKey('raw'),
              initialUrlRequest: inapp.URLRequest(
                url: inapp.WebUri('http://$originHost:$port/raw'),
              ),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-binding-raw',
                proxySettings: inapp.ProxySettings(
                  proxyRules: [
                    inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}'),
                  ],
                  bypassRules: [],
                ),
              ),
              onWebViewCreated: (c) => raw = c,
            ),
          ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    // (1) Two proxied webviews in the process's first frame. Established
    // over three runs; the floor for everything below.
    // Measure every factor first, record every one, and only then assert.
    // Last run asserted between measurements and the `deferred` failure
    // aborted the test before `persist` was reached -- so the factor that
    // decides whether any fix is worth building was the one the factorial
    // lost. Assertions at the end cannot suppress a measurement.
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
    final pairLoads = socks.targets.length + direct.length;

    await waitReal(tester, () => requests.contains('/refused'),
        label: 'refused load (must not arrive)',
        timeout: const Duration(seconds: 10));
    final refusedLeaked = requests.contains('/refused');
    verdict.add('refused=${refusedLeaked ? "DIRECT" : "failed closed"}');

    // `persist` twice, by the two different kinds of navigation, because
    // last run measured it only the programmatic way and came back DIRECT.
    // That conclusion -- a binding covers one load, so the feature cannot be
    // delivered at all -- is strong enough that it must not rest on a code
    // path no user ever exercises. `nativeController.loadUrl` and a page
    // setting `location.href` are different paths through WebKit, and only
    // the second is what a user produces by following a link.
    //
    // It also sits badly with the report this bug came from: a user who saw
    // only their first load proxied would have noticed immediately, not
    // described it as "sometimes I have to restart the app".

    // (3) In-page: /pair-a's own page navigates itself after 5s.
    final inPageProxied = await waitReal(
        tester, () => socks.targets.contains('$originHost:$persistPort'),
        label: 'in-page navigation of a bound webview',
        timeout: const Duration(seconds: 25));
    final inPageDirect = requests.contains('persist:/p');
    verdict.add('persist-inpage=${inPageProxied ? "proxied" : inPageDirect ? "DIRECT" : "no load"}');

    // (4) Programmatic: the same second navigation, issued from Dart on the
    // other bound webview. If this is DIRECT while (3) is proxied, last
    // run's verdict was an artifact of the harness.
    final pairReady = await waitReal(tester, () => paneB != null,
        label: 'pair-b controller created');
    if (pairReady) {
      await tester.runAsync(() async {
        await paneB!.nativeController.loadUrl(
          urlRequest: inapp.URLRequest(
            url: inapp.WebUri('http://$originHost:$factoryPort/d'),
          ),
        );
      });
      await waitReal(
          tester, () => socks.targets.contains('$originHost:$factoryPort'),
          label: 'programmatic navigation of a bound webview');
    }
    final loadUrlProxied =
        socks.targets.contains('$originHost:$factoryPort');
    final loadUrlDirect = requests.contains('factory:/d');
    verdict.add('persist-loadurl=${!pairReady ? "no controller" : loadUrlProxied ? "proxied" : loadUrlDirect ? "DIRECT" : "no load"}');

    // (5) The plain WebKit navigation. `raw-first` is the floor for it: if
    // the raw webview did not bind in this frame, `raw-second` says nothing.
    final rawFirst = await waitReal(
        tester, () => requests.contains('/raw') || socks.targets.length >= 3,
        label: 'raw webview first load', timeout: const Duration(seconds: 15));
    final rawFirstDirect = requests.contains('/raw');
    verdict.add('raw-first=${rawFirstDirect ? "DIRECT" : rawFirst ? "proxied" : "no load"}');
    if (raw != null) {
      await tester.runAsync(() async {
        await raw!.loadUrl(
          urlRequest: inapp.URLRequest(
            url: inapp.WebUri('http://$originHost:$deferredPort/raw2'),
          ),
        );
      });
      await waitReal(
          tester, () => socks.targets.contains('$originHost:$deferredPort'),
          label: 'raw webview second load');
    }
    final rawSecondProxied =
        socks.targets.contains('$originHost:$deferredPort');
    final rawSecondDirect = requests.contains('deferred:/raw2');
    verdict.add('raw-second=${raw == null ? "no controller" : rawSecondProxied ? "proxied" : rawSecondDirect ? "DIRECT" : "no load"}');

    // Now assert, floor first.
    expect(
      pairLoads,
      2,
      reason: 'the two panes issued $pairLoads loads between them, not 2, so '
          'this measured the mount rather than the binding',
    );
    expect(both, isTrue,
        reason: 'a proxied webview built in the first frame did not use its '
            'proxy, so nothing else in this file holds');
    expect(
      refusedLeaked,
      isFalse,
      reason: 'a site whose proxy refuses connections reached the origin '
          'anyway, which a bound proxy cannot do',
    );
    expect(
      inPageDirect,
      isFalse,
      reason: 'a webview that used its proxy for its first load went direct '
          'when its own page followed a link, so the binding covers one load '
          'and the site leaks on everything the user clicks',
    );
    expect(
      loadUrlDirect,
      isFalse,
      reason: 'the same second navigation, issued from Dart, went direct',
    );
  });

  testWidgets('measurement: two proxied webviews in a later frame',
      (tester) async {
    // A measurement, not an assertion. "First frame" is how the rule reads
    // after three runs, but every pair that bound was also the process's
    // first mount, so "any frame carrying more than one webview" fits the
    // same data. This separates them, and the answer changes what the app
    // has to do: build every proxied site at startup, or merely build them
    // together whenever they are built.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    Widget pane(String siteId, String path) => SizedBox(
          width: 320,
          height: 160,
          child: WebViewFactory.createWebView(
            config: WebViewConfig(
              siteId: siteId,
              initialUrl: 'http://$originHost:$port$path',
              proxySettings: liveProxy(),
              clearUrlEnabled: false,
              dnsBlockEnabled: false,
              contentBlockEnabled: false,
              trackingProtectionEnabled: false,
              localCdnEnabled: false,
            ),
            onControllerCreated: (_) {},
          ),
        );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          KeyedSubtree(
              key: const ValueKey('late-a'),
              child: pane('proxy-binding-late-a', '/late-a')),
          KeyedSubtree(
              key: const ValueKey('late-b'),
              child: pane('proxy-binding-late-b', '/late-b')),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    await waitReal(tester, () => socks.targets.length >= 2,
        label: 'two proxied sites built in a later frame',
        timeout: const Duration(seconds: 25));
    final direct = [
      if (requests.contains('/late-a')) 'a',
      if (requests.contains('/late-b')) 'b',
    ];
    verdict.add('later-pair=${socks.targets.length} of 2 proxied, '
        'direct=${direct.isEmpty ? "none" : direct.join("+")}');
  });

  testWidgets('the harness can see a load reach the origin', (tester) async {
    // The control. Without it, every assertion above passes for any reason a
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
