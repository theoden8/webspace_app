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

  testWidgets('two proxied sites mounted side by side both use their proxy',
      (tester) async {
    // First in the file, and this one is a test of the *fix*, not of the
    // diagnosis.
    //
    // If only the store registered while the network process is still
    // launching gets its proxy through the session's creation parameters,
    // then arming several stores inside one turn of the run loop -- before
    // anything else in the process has touched the network -- should put
    // all of them in that same snapshot. Two container stores built in one
    // `pumpWidget`, before any other store exists, is that arrangement, and
    // it is the shape a real fix would take: pre-arm every proxied site's
    // container at startup rather than when its webview is built.
    //
    // 2 of 2 means the fix works and per-site proxies survive with their
    // containers intact. 1 of 2 means exactly one store per process can be
    // proxied whatever the ordering, and the design is forced: route
    // proxied sites through one store and serialise the ones that disagree.
    // 0 of 2 with `direct=none` means the mount issued no loads and the run
    // says nothing.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    Widget pane(String siteId, String path) => SizedBox(
          width: 320,
          height: 240,
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
              key: const ValueKey('side-a'),
              child: pane('proxy-binding-side-a', '/side-a')),
          KeyedSubtree(
              key: const ValueKey('side-b'),
              child: pane('proxy-binding-side-b', '/side-b')),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    final both = await waitReal(
      tester,
      () => socks.targets.length >= 2,
      label: 'two simultaneous proxied loads',
      timeout: const Duration(seconds: 25),
    );
    // Where the two loads went if not through the proxy. Without this a
    // count of zero has two readings -- both bound nothing and went direct,
    // or neither load was ever issued because two platform views in one
    // tree do not both come up -- and only the first says anything about
    // binding.
    final direct = [
      if (requests.contains('/side-a')) 'a',
      if (requests.contains('/side-b')) 'b',
    ];
    verdict.add('side-by-side=${socks.targets.length} of 2 proxied, '
        'direct=${direct.isEmpty ? "none" : direct.join("+")}');
    expect(
      socks.targets.length + direct.length,
      2,
      reason: 'the two panes issued ${socks.targets.length + direct.length} '
          'loads between them, not 2, so this scenario measured the mount '
          'rather than the binding',
    );
    expect(
      both,
      isTrue,
      reason: 'two sites live at once, each with its own container and the '
          'same proxy, and the fixture proxy saw ${socks.targets.length} of '
          'them: binding is not simply a property of being first',
    );
  });

  testWidgets('a proxy armed before any store exists reaches the default store',
      (tester) async {
    // The only scenario in this file that loads on
    // `WKWebsiteDataStore.default()` rather than a container store, which
    // is the store the fallback design would route proxied sites through.
    //
    // Reading WebKit's own source says the asymmetry is about *registration
    // order with the network process*, not about the store. A store's proxy
    // reaches the network process two ways: in the parameters that create
    // its session, or as an update afterwards. `WebsiteDataStore::
    // setProxyConfigData` clears the stored data, calls `networkProcess()`
    // -- which registers the session, taking the parameters right then --
    // and only then puts the data back, so the assignment that registers a
    // session can never carry the proxy in its parameters. Only a store
    // registered while the network process is still coming up escapes,
    // because that snapshot is read after the call returns.
    //
    // The default store is not first here: the two container stores above
    // are. So under that rule this is DIRECT, and the value of the scenario
    // is that it says whether the default store behaves any differently
    // from a container one when it is late. If it does, the fallback design
    // has to know that.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await tester.runAsync(() async {
      await inapp.ProxyController.instance().setProxyOverride(
        settings: inapp.ProxySettings(
          proxyRules: [
            inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}'),
          ],
          bypassRules: [],
        ),
      );
    });
    // No siteId: `siteOwnsContainerProfile` binds nothing, so this webview
    // gets the default store, which is what the override reaches.
    await mount(tester, siteId: null, path: '/global-early');
    final used = await waitReal(tester, () => socks.targets.isNotEmpty,
        label: 'override armed before any container store');
    verdict.add('global-early=${used ? "proxied" : "DIRECT"}');
    // Cleared before anything else runs: an active override is replayed
    // onto every container store created afterwards, which would confound
    // every per-site scenario below.
    await tester.runAsync(
        () async => inapp.ProxyController.instance().clearProxyOverride());
    expect(
      used,
      isTrue,
      reason: 'a proxy armed on the default store before any other store '
          'existed still did not route its load, so there is no store in an '
          'Apple process that can be proxied reliably and the per-site '
          'feature cannot be delivered by any assignment',
    );
  });

  testWidgets('a container site with its own proxy, no longer registered first',
      (tester) async {
    // This is the scenario that has bound its proxy in every run of this
    // file, back when it was the first store the process registered. Three
    // stores are registered ahead of it now.
    //
    // If it goes direct here having passed before, nothing about the site,
    // the container or the proxy changed -- only that other stores got
    // there first. That is the whole diagnosis, measured rather than
    // argued.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      siteId: 'proxy-binding-first',
      path: '/first-in-process',
      proxySettings: liveProxy(),
    );
    final used = await waitReal(tester, () => socks.targets.isNotEmpty,
        label: 'container proxied load, registered second');
    verdict.add('second-container=${used ? "proxied" : "DIRECT"}');
    expect(
      used,
      isTrue,
      reason: 'a container store registered after another store does not get '
          'its proxy: the binding belongs to whichever store the network '
          'process saw first, so only one proxied site per app launch works',
    );
    if (used) expect(socks.targets.first, '$originHost:$port');
  });

  testWidgets('the harness can see a load reach the origin', (tester) async {
    // The control. Without it, the assertions below pass for any reason a
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
    expect(socks.targets, isEmpty,
        reason: 'an unproxied site went through the fixture proxy');
  });

  testWidgets("a fresh site's first webview loads through its proxy",
      (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      // Below iOS 17 / macOS 14 the app blanks the load instead
      // (`proxyUnavailable`), which is a different contract with its own
      // coverage.
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      // Its own site, so the container store this webview gets has never
      // served a load: binding at construction is what this asserts, and
      // re-binding a store that is already in use is the scenario below.
      siteId: 'proxy-binding-fresh',
      path: '/proxied',
      proxySettings: liveProxy(),
    );
    final freshUsed = await waitReal(tester, () => socks.targets.isNotEmpty,
        label: 'proxied load (must arrive at the proxy)');
    verdict.add('fresh-site=${freshUsed ? "proxied" : "DIRECT"}');
    expect(
      freshUsed,
      isTrue,
      reason: 'the fixture proxy was never asked for anything: the per-site '
          'proxy was not bound to the engine, so every proxied site is '
          'loading over the device IP',
    );
    expect(socks.targets.first, '$originHost:$port');
    expect(
      await waitReal(tester, () => requests.contains('/proxied'),
          label: 'proxied load (relayed to the origin)'),
      isTrue,
    );
  });

  testWidgets('the engine received the proxy Dart sent it', (tester) async {
    // Splits the seam the other scenarios can only see the far side of. The
    // proxy is one field on `InAppWebViewSettings`, delivered over a method
    // channel and parsed reflectively; `getSettings()` asks the engine what
    // it actually holds. A null here means the field never crossed, which is
    // a different bug from a field that crossed and was not applied -- and
    // the load-level assertions cannot tell them apart.
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
    expect(await waitReal(tester, () => controller != null,
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

  testWidgets('a site whose proxy is refused never reaches the origin',
      (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      siteId: 'proxy-binding-refused',
      path: '/refused',
      proxySettings: refusedProxy(),
    );
    // Long enough for a direct load to have happened many times over; the
    // proxied one cannot succeed at all.
    await waitReal(tester, () => requests.contains('/refused'),
        label: 'refused load (must not arrive)',
        timeout: const Duration(seconds: 15));
    verdict.add(
        'refused=${requests.contains('/refused') ? "DIRECT" : "failed closed"}');
    expect(
      requests,
      isNot(contains('/refused')),
      reason: 'the request reached the origin directly: a proxy that cannot '
          'be connected to fell back to the device IP instead of failing '
          'the load',
    );
  });

  testWidgets('a site that gains a proxy stops going direct', (tester) async {
    // The reported symptom: "sometimes I have to restart the app for the Tor
    // proxy to start working". A site's container data store outlives its
    // webview -- the plugin caches one per container for the process -- so
    // the proxy for a second webview is assigned to a store that has already
    // served a load. If that assignment does not take, the only thing that
    // ever binds a proxy is the first webview a site gets, and restarting
    // the app is the only way to change it.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    const siteId = 'proxy-binding-rebind';
    await mount(tester, siteId: siteId, path: '/first');
    expect(
      await waitReal(tester, () => requests.contains('/first'),
          label: 'unproxied first load'),
      isTrue,
      reason: 'the site never loaded at all, so the rebind below proves '
          'nothing',
    );

    await mount(
      tester,
      siteId: siteId,
      path: '/second',
      proxySettings: liveProxy(),
    );
    final reboundUsed = await waitReal(
        tester, () => socks.targets.isNotEmpty,
        label: 'rebound load (must arrive at the proxy)');
    verdict.add('rebind=${reboundUsed ? "proxied" : "DIRECT"}');
    expect(
      reboundUsed,
      isTrue,
      reason: 'a proxy assigned to a container store that has already served '
          'a load does not take effect, so a site keeps whatever proxy its '
          'first webview was built with until the app restarts',
    );
    expect(socks.targets.last, '$originHost:$port');
    expect(
      await waitReal(tester, () => requests.contains('/second'),
          label: 'rebound load (relayed to the origin)'),
      isTrue,
    );
  });

  testWidgets('a process-wide override reaches a webview built later',
      (tester) async {
    // The other end of the bracket. The scenario at the top of the file
    // arms the same override before any store exists and loads it on the
    // default store; this one arms it once a dozen stores are registered
    // and loads it on a container store created afterwards, which reaches
    // it through `ProxyManager.applyActiveProxyOverride`.
    //
    // Early-and-default against late-and-container is the whole design
    // question: if the first is proxied and this one is not, the shape that
    // works is one store armed at startup with sites serialised onto it
    // (PROXY-013, which Android already runs). If neither is proxied, no
    // assignment in an Apple process reaches a second store at all.
    //
    // Last in the file deliberately: it leaves process-wide state behind.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await tester.runAsync(() async {
      await inapp.ProxyController.instance().setProxyOverride(
        settings: inapp.ProxySettings(
          proxyRules: [inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}')],
          bypassRules: [],
        ),
      );
    });
    // No per-site proxy: the override is the only thing that could route
    // this load, so a CONNECT at the fixture can only have come from it.
    await mount(tester, siteId: 'proxy-binding-global', path: '/global');
    final used = await waitReal(tester, () => socks.targets.isNotEmpty,
        label: 'process-wide override load');
    verdict.add('global-override=${used ? "proxied" : "DIRECT"}');
    await tester.runAsync(
        () async => inapp.ProxyController.instance().clearProxyOverride());
    expect(
      used,
      isTrue,
      reason: 'the process-wide override did not reach a webview built after '
          'the first one either, so no proxy of any kind can be applied to a '
          'second data store in an Apple process',
    );
  });
}
