// The same simultaneity question as `proxy_simultaneous_test.dart`, asked
// of an HTTP CONNECT proxy instead of a SOCKS5 one.
//
// This is not a variation for its own sake. WebKit installs a data store's
// proxy by one of two routes and the caller does not choose:
// `NetworkSessionCocoa::setProxyConfigData` asks
// `nw_proxy_config_stack_requires_http_protocols` about each configuration.
// If any answers yes it rebuilds every NSURLSession with the proxy on that
// session's own `NSURLSessionConfiguration`
// (`SessionWrapper::recreateSessionWithUpdatedProxyConfigurations`) -- per
// session, nothing shared. If none does it instead patches the live
// `nw_context`, clearing that context's proxies first, and it collects
// those contexts into an `NSMutableSet` across session wrappers, which is
// only worth doing if two wrappers can hand back the same one.
//
// A SOCKS5 proxy takes the patching route. Every reading in BUG-014 was
// taken through a SOCKS5 proxy. If a shared context is what makes the
// second store's proxy replace the first, an HTTP CONNECT proxy should not
// show it, because it takes the other route -- and that is not an argument
// anyone can settle by reading more source, so it is measured here.
//
// Three panes, three separate proxies, all in the process's first frame,
// which is the one arrangement where a single proxy is known to bind.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'fixture_server.dart';
import 'http_connect_fixture.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-http-connect] $m');
  }

  const paneCount = 3;

  final proxies = <HttpConnectFixture>[];
  final origins = <HttpServer>[];
  final ports = <int>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;

  final trace =
      File('${Directory.systemTemp.path}/webspace-container-store.log');
  final verdict = <String>[];

  setUpAll(() async {
    if (trace.existsSync()) trace.deleteSync();
    if (applies) {
      containers = await ContainerNative.instance.isSupported();
    }
    // Without this `isProxySupported` is false and every scenario
    // below skips, which is how the first run of these files
    // reported green having measured nothing.
    await PlatformInfo.initialize();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';

    for (var i = 0; i < paneCount; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('h$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>h$i</p></body></html>');
        await res.close();
      });
      proxies.add(await HttpConnectFixture.bind());
    }
    log('origins ${ports.join(",")} on $originHost, '
        'http proxies ${proxies.map((p) => p.port).join(",")}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    for (var f = 0; f < proxies.length; f++) {
      log('proxy$f connects=${proxies[f].targets}');
    }
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    if (trace.existsSync()) {
      for (final line in trace.readAsLinesSync()) {
        log('native: $line');
      }
      trace.deleteSync();
    } else {
      log('native: no container-store trace was written');
    }
    for (final p in proxies) {
      await p.close();
    }
    for (final o in origins) {
      await o.close(force: true);
    }
  });

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
    // Not a skip. Every Apple tier this runs on is past the
    // proxyConfigurations floor, so a false here means PlatformInfo was
    // never initialized rather than an old OS -- and skipping on it is
    // indistinguishable, in the tier's output, from a file that ran.
    expect(
      PlatformInfo.isProxySupported,
      isTrue,
      reason: 'proxy support reads as unavailable on an Apple tier that is '
          'past the iOS 17 / macOS 14 floor; PlatformInfo.initialize() was '
          'most likely not awaited in setUpAll',
    );
    return true;
  }

  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 30),
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

  int? proxyThatSaw(String target) {
    for (var f = 0; f < proxies.length; f++) {
      if (proxies[f].targets.contains(target)) return f;
    }
    return null;
  }

  testWidgets('the first frame: three stores, three HTTP CONNECT proxies',
      (tester) async {
    if (!usable()) return;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          for (var i = 0; i < paneCount; i++)
            SizedBox(
              width: 200,
              height: 90,
              child: inapp.InAppWebView(
                key: ValueKey('httpc$i'),
                initialUrlRequest: inapp.URLRequest(
                  url: inapp.WebUri('http://$originHost:${ports[i]}/h$i'),
                ),
                initialSettings: inapp.InAppWebViewSettings(
                  containerId: 'ws-proxy-httpc-$i',
                  proxySettings: inapp.ProxySettings(
                    proxyRules: [
                      inapp.ProxyRule(
                        url: 'http://127.0.0.1:${proxies[i].port}',
                      ),
                    ],
                    bypassRules: [],
                  ),
                ),
              ),
            ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) =>
        proxyThatSaw('$originHost:${ports[i]}') != null ||
        requests.contains('h$i:/h$i');

    await waitReal(
      tester,
      () => List.generate(paneCount, settled).every((s) => s),
      label: 'every HTTP CONNECT pane settled',
    );

    final results = <String>[];
    for (var i = 0; i < paneCount; i++) {
      final saw = proxyThatSaw('$originHost:${ports[i]}');
      results.add('h$i->${saw == i ? 'own(proxy$saw)' : saw != null ? 'CROSSED(proxy$saw)' : requests.contains('h$i:/h$i') ? 'DIRECT' : 'no load'}');
    }
    verdict.add('http-connect=[${results.join(" ")}]');

    final own = results.where((r) => r.contains('own(')).length;
    log('$own of $paneCount HTTP CONNECT panes used their own proxy');

    expect(
      own,
      paneCount,
      reason: 'three stores in the first frame, three distinct HTTP CONNECT '
          'proxies: every pane must reach its origin through its own. Got '
          '[${results.join(" ")}]. If SOCKS5 fails the same shape and this '
          'passes, the live nw_context patch is the mechanism and an HTTP '
          'proxy is the delivery that works',
    );
  });

  testWidgets('a SOCKS5 pane in a later frame, for the contrast',
      (tester) async {
    if (!usable()) return;
    // Deliberately one pane and one proxy: this is not a simultaneity
    // question, it is the control that says whether this process reaches a
    // proxy at all outside its first frame, so a null result above can be
    // told apart from a process that had stopped proxying anything.
    final socks = await Socks5Fixture.bind();
    final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    listenFixture(origin, (req) async {
      requests.add('ctl:${req.uri.path}');
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>ctl</p></body></html>');
      await res.close();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 90,
          child: inapp.InAppWebView(
            key: const ValueKey('httpc-control'),
            initialUrlRequest: inapp.URLRequest(
              url: inapp.WebUri('http://$originHost:${origin.port}/ctl'),
            ),
            initialSettings: inapp.InAppWebViewSettings(
              containerId: 'ws-proxy-httpc-control',
              proxySettings: inapp.ProxySettings(
                proxyRules: [
                  inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}'),
                ],
                bypassRules: [],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    final target = '$originHost:${origin.port}';
    await waitReal(
      tester,
      () => socks.targets.contains(target) || requests.contains('ctl:/ctl'),
      label: 'later-frame SOCKS control settled',
    );
    verdict.add('later-socks-control=${socks.targets.contains(target) ? "proxied" : requests.contains('ctl:/ctl') ? "DIRECT" : "no load"}');

    await socks.close();
    await origin.close(force: true);
  });
}
