// What "only the first WebView in the process is proxied" keys on (BUG-014).
//
// This file started as a three-shape comparison and that question is closed:
// run 3125 put one bare WKWebView ahead of the frame and it bound while the
// three app-built shapes behind it went direct, the same three that bound in
// runs 3123/3124 when nothing ran ahead of them. Construction is not the
// variable. Order is.
//
// What order means is still three claims stuck together, because that arm was
// the first WebView, the first load and the first store handed a proxy at
// once. The arms ahead of the frame now take them apart: an unproxied first
// WebView, then a proxied one, then a proxied one through a second SOCKS
// endpoint -- the first time two distinct endpoints are asked for in one
// process, which is what a Tor site and a plain proxy site are.
//
// The three original shapes stay, now as a control on the other side of the
// slot: whatever the arms ahead of them do, they must still load.
//
//  A  a raw plugin webview with its proxy on `initialSettings` and its load
//     on `initialUrlRequest`.
//  B  the same site through `WebViewFactory.createWebView`, which is what the
//     app itself uses.
//  C  a raw webview with no initial request, loaded by `loadUrl` from
//     `onWebViewCreated`.
//
// Separate origins throughout, so a recorded CONNECT is attributable to one
// arm.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-shape] $m');
  }

  const shapes = ['raw-initial', 'factory', 'raw-loadurl'];

  /// Where in the tier this process ran. The loop runs this file twice, once
  /// ahead of every other integration file and once in its alphabetical
  /// position, because proxy_binding -- the first proxy file the glob reaches
  /// -- is the only arm that binds and every arm behind it does not.
  final position = Platform.environment['WEBSPACE_TIER_POSITION'] ?? 'glob';

  /// Whether to delete the stored containers before creating this run's own.
  /// Run 3106 is the reason it is a knob: eight launches back to back, and
  /// the only one that bound a proxy was the one that found nothing to
  /// delete. The other seven each deleted three first and all seven went
  /// direct. That is either a coincidence or the sweep itself, and the sweep
  /// is code this investigation added.
  /// `on` deletes the stored containers, `list` and `off` do not. Every mode
  /// now lists them, because a launch that cannot say what it started with
  /// cannot be read afterwards (attempt 52): the listing is one channel round
  /// trip into `WKWebsiteDataStore.fetchAllDataStoreIdentifiers`, and runs
  /// 3106 through 3111 give no sign that it changes what binds.
  final sweepMode = Platform.environment['WEBSPACE_SHAPE_SWEEP'] ?? 'on';
  final lists = sweepMode != '0' && sweepMode != 'off';
  final deletes = lists && sweepMode != 'list';

  /// `purge` deletes every stored container and mounts nothing, so the next
  /// process starts with none. It was built to test the count a process
  /// starts with, which attempt 52 refuted; what it is still good for is
  /// putting a launch that binds and a launch that does not one minute
  /// apart in the same run, which is the comparison the assignment trace
  /// wants.
  final purges = sweepMode == 'purge';

  /// What the process's FIRST WebView carries. Run 3127 is the reason it is a
  /// knob: its first launch was byte-identical in conditions to run 3125's
  /// (position=first, started=0, nothing swept) and differed only in that its
  /// first WebView carried no proxy. Run 3125 proxied; 3127 went direct on
  /// every arm, the proxied ones included. `proxied` restores 3125's arm and
  /// is the positive control; `noproxy` is the intervention.
  final firstArm = Platform.environment['WEBSPACE_SHAPE_FIRSTARM'] ?? 'proxied';

  late Socks5Fixture socks;
  /// A second, distinct SOCKS5 endpoint. Attempt 59 needs one because
  /// every arm after the first in run 3125 shared *one* endpoint and went
  /// direct, so "one proxy per process" and "one endpoint per process"
  /// are still the same reading.
  late Socks5Fixture socksB;
  final origins = <HttpServer>[];
  final ports = <int>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;
  var swept = -1;

  /// How many stored containers this process found at launch, measured on
  /// every launch whatever the sweep does. Attempt 52 could not tell whether
  /// `probe1-b` really started with none because only the sweeping modes
  /// looked, and a purge never checked its own work. Both are measured now.
  var started = -1;
  var left = -1;

  /// Where the plugin writes its account of every `proxyConfigurations`
  /// assignment. A file because `flutter test` does not capture the host
  /// app's stdout and the test runs inside that app.
  final trace =
      File('${Directory.systemTemp.path}/webspace-container-store.log');
  final results = <String>[];

  setUpAll(() async {
    if (!applies) return;
    // This order is the point: proxy_binding initializes PlatformInfo first
    // and is the only arm that binds.
    // One file per app process into the same path, so without this the
    // trace carries entries from an earlier file's process.
    if (trace.existsSync()) trace.deleteSync();
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();

    final stale = await ContainerNative.instance.listContainers();
    started = stale.length;
    if (deletes) {
      for (final siteId in stale) {
        await ContainerNative.instance.deleteContainer(siteId);
      }
      swept = stale.length;
      left = (await ContainerNative.instance.listContainers()).length;
    }

    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();
    socksB = await Socks5Fixture.bind();

    for (var i = 0; i < shapes.length; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('s$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>s$i</p></body></html>');
        await res.close();
      });
    }
    log('position=$position, sweep=$sweepMode, firstArm=$firstArm, '
        'started=$started, '
        'swept=$swept, left=$left, '
        'origins ${ports.join(",")} on $originHost, '
        'socks ${socks.port}/${socksB.port}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    log('socks connects=${socks.targets}, socksB connects=${socksB.targets}');
    if (trace.existsSync()) {
      for (final line in trace.readAsLinesSync()) {
        log('native: $line');
      }
      trace.deleteSync();
    } else {
      log('native: no container-store trace was written');
    }
    log('verdict: containers=$containers, position=$position, '
        'sweep=$sweepMode, firstArm=$firstArm, '
        'started=$started, swept=$swept, left=$left, '
        'shape=[${results.join(" ")}]');
    await socks.close();
    await socksB.close();
    for (final o in origins) {
      await o.close(force: true);
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4; Apple never proxies a loopback '
            'destination, so nothing here could be distinguished');
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable on an Apple tier past the '
            'floor; PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

  inapp.ProxySettings rawProxy() => inapp.ProxySettings(
        proxyRules: [inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}')],
        bypassRules: [],
      );

  testWidgets('three shapes, one frame, one endpoint', (tester) async {
    if (!usable()) return;
    if (purges) {
      log('purged $swept of $started container(s), $left left; '
          'mounting nothing');
      return;
    }

    // Run 3127 answered what "first" keys on, by accident and decisively.
    // Its first launch matched run 3125's in every condition the file
    // records -- position=first, started=0, nothing swept -- and differed in
    // one thing: its first WebView carried no proxy. 3125 proxied its first
    // arm; 3127 went direct on all nine, the proxied ones included, each
    // reporting configured=1 and a finished load.
    //
    // So the slot is claimed by the first WebView in the process whether or
    // not it carries a proxy, and an unproxied first load spends it. That is
    // the shape of "sometimes I have to restart the app for Tor to work": a
    // session whose first site is not proxied has no proxy for any site.
    //
    // The arms now carry a positive control for it, because a run where
    // nothing proxies is also what a dead launch looks like (run 3125's glob
    // position went direct on a *proxied* first arm, which no ordering rule
    // explains and which is still open):
    //
    //  first-<mode>   `proxied` restores 3125's arm and must bind, which is
    //                 what makes the rest of the launch readable at all;
    //                 `noproxy` is the intervention.
    //  second-proxy-A the next WebView, proxied. Direct behind a proxied
    //                 first arm is the one-slot rule; direct behind an
    //                 unproxied one is the slot being spent by a load that
    //                 wanted nothing.
    //  third-proxy-B  a third WebView through a *different* endpoint. Every
    //                 arm that went direct so far shared one endpoint with
    //                 the arm that bound, so "one proxy per process" and
    //                 "one endpoint per process" have never been apart.
    Future<void> probe(String label,
        {bool identified = false,
        bool attach = false,
        bool proxy = true,
        Socks5Fixture? via}) async {
      if (!hostIsMacOS) return;
      final fixture = via ?? socks;
      final before = fixture.targets.length;
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      listenFixture(origin, (req) async {
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>$label</p></body></html>');
        await res.close();
      });
      // Bounded and total: these are diagnostics riding along in a test that
      // measures something else. A probe that throws, or whose WebView never
      // reaches a terminal navigation callback so the reply never comes,
      // must not take the three shapes down with it.
      try {
        final reply = await const MethodChannel('webspace/proxy_probe')
            .invokeMapMethod<String, dynamic>('probe', {
          'socksHost': '127.0.0.1',
          'socksPort': fixture.port,
          'url': 'http://$originHost:${origin.port}/',
          'identified': identified,
          'identifier': '8f1d5c4e-0000-4000-8000-0000000000${identified ? 11 : 12}',
          'attach': attach,
          'proxy': proxy,
        }).timeout(const Duration(seconds: 30));
        final outcome = fixture.targets.length > before ? 'proxied' : 'DIRECT';
        results.add('$label->$outcome');
        log('$label -> $outcome (ok=${reply?['ok']} '
            'configured=${reply?['configured']} detail=${reply?['detail']})');
      } catch (e) {
        // Still worth a reading: the SOCKS fixture records a CONNECT when it
        // happens, whatever the reply did.
        final outcome = fixture.targets.length > before ? 'proxied' : 'DIRECT';
        results.add('$label->$outcome');
        log('$label -> $outcome, probe did not report: $e');
      } finally {
        await origin.close(force: true);
      }
    }

    await tester.runAsync(
        () => probe('first-$firstArm', proxy: firstArm != 'noproxy'));
    await tester.runAsync(() => probe('second-proxy-A'));
    await tester.runAsync(() => probe('third-proxy-B', via: socksB));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SizedBox(
            width: 320,
            height: 110,
            child: inapp.InAppWebView(
              key: const ValueKey('shape-raw-initial'),
              initialUrlRequest: inapp.URLRequest(
                url: inapp.WebUri('http://$originHost:${ports[0]}/s0'),
              ),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-shape-0-$position',
                proxySettings: rawProxy(),
              ),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('shape-factory'),
            child: SizedBox(
              width: 320,
              height: 110,
              child: WebViewFactory.createWebView(
                config: WebViewConfig(
                  siteId: 'proxy-shape-1-$position',
                  initialUrl: 'http://$originHost:${ports[1]}/s1',
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
                onControllerCreated: (_) {},
              ),
            ),
          ),
          SizedBox(
            width: 320,
            height: 110,
            child: inapp.InAppWebView(
              key: const ValueKey('shape-raw-loadurl'),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-shape-2-$position',
                proxySettings: rawProxy(),
              ),
              onWebViewCreated: (c) {
                c.loadUrl(
                  urlRequest: inapp.URLRequest(
                    url: inapp.WebUri('http://$originHost:${ports[2]}/s2'),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) =>
        socks.targets.contains('$originHost:${ports[i]}') ||
        requests.contains('s$i:/s$i');

    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (List.generate(shapes.length, settled).every((s) => s)) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });

    for (var i = 0; i < shapes.length; i++) {
      final outcome = socks.targets.contains('$originHost:${ports[i]}')
          ? 'proxied'
          : requests.contains('s$i:/s$i')
              ? 'DIRECT'
              : 'no-load';
      results.add('${shapes[i]}->$outcome');
      log('${shapes[i]} -> $outcome');
    }

    // Tail controls. Run 3125 had all three read DIRECT behind an arm that
    // bound, which is how attempt 58 was established; they stay so that a run
    // where the slot reopens -- after a frame, after a store is torn down,
    // after anything -- shows up here rather than being assumed away.
    await probe('bare');
    await probe('bare-ident', identified: true);
    await probe('bare-window', attach: true);

    // What this file can still assert is the tier, not the bug. Attempt 58
    // showed the three app shapes bind or not according to whether something
    // ran ahead of them, so "every shape binds" is a claim about arm order,
    // not about the code under test, and a probe now always runs first. The
    // finding lives in the verdict line; what must not regress is that every
    // arm reached a terminal outcome -- a `no-load` or a missing probe means
    // the fixture, the origin server or the channel broke, and then the whole
    // reading is noise rather than a result.
    final loaded = results.where((r) => !r.endsWith('no-load')).length;
    expect(
      loaded,
      results.length,
      reason: 'an arm never reached a terminal outcome, so this run measures '
          'nothing. Got [${results.join(" ")}]',
    );
    expect(
      results.length,
      shapes.length + (hostIsMacOS ? 6 : 0),
      reason: 'an arm did not report at all. Got [${results.join(" ")}]',
    );
  });
}
