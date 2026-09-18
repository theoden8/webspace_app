// The CONNECT arm, made fair.
//
// `proxy_http_connect_test.dart` came back with every proxy fixture showing
// `connects=[]` -- WebKit contacted none of them -- and that was read as "an
// HTTP CONNECT proxy does not help". It measured nothing of the sort. The
// arm loaded `http://` origins, and a CONNECT proxy is a tunnel: upstream,
// every CONNECT-proxy test in WebKit's own `Proxy.mm` loads an **https**
// destination through it (`ProxyAfterNetworkProcessCrash`), while the SOCKS5
// test beside it loads plain `http://` and its proxy *is* used. A
// transport-level proxy config plausibly declines to tunnel plaintext http,
// where the convention is an absolute-URI request rather than CONNECT -- and
// the fixture here records both forms, so `connects=[]` means neither was
// sent.
//
// Corrected too: `Protocol::HttpsProxy` upstream is NOT a TLS-wrapped proxy.
// `HTTPServerCore.swift:252` builds `NWParameters(tls: nil)`, inserts the
// CONNECT framer, then inserts TLS *above* it -- a plaintext proxy whose TLS
// belongs to the tunnelled destination. So the proxy stays plaintext here and
// the **origins** get TLS, which is the one variable that differed.
//
// The certificate is minted in Dart at run time (`self_signed_cert.dart`), so
// no private key is committed and the arm does not depend on a binary the
// macOS tier does not have.

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
import 'self_signed_cert.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-connect-https] $m');
  }

  const paneCount = 3;

  final proxies = <HttpConnectFixture>[];
  final origins = <HttpServer>[];
  final ports = <int>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;
  final verdict = <String>[];

  // A SOCKS pane in the same first frame of the same process. Every CONNECT
  // arm has read DIRECT with an idle fixture in every run, and run 3097 also
  // produced a process that proxied nothing at all; from outside the two look
  // the same. If this binds and the CONNECT panes beside it do not, the
  // delivery is the variable rather than the process.
  late Socks5Fixture controlSocks;
  late HttpServer controlOrigin;
  var controlPort = 0;
  var control = 'not run';


  setUpAll(() async {
    if (!applies) return;
    // Ordered the way proxy_binding orders it, which is the only arm that
    // binds a proxy. Whether that matters is unmeasured; removing the
    // difference costs nothing and leaves one fewer variable.
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';

    final ctx = generateSelfSignedCert(
      commonName: originHost,
      ipAddresses: {originHost, '127.0.0.1'}.toList(),
    ).serverContext();

    for (var i = 0; i < paneCount; i++) {
      final origin =
          await HttpServer.bindSecure(InternetAddress.anyIPv4, 0, ctx);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('c$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>c$i</p></body></html>');
        await res.close();
      });
      proxies.add(await HttpConnectFixture.bind());
    }
    controlSocks = await Socks5Fixture.bind();
    controlOrigin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    controlPort = controlOrigin.port;
    listenFixture(controlOrigin, (req) async {
      requests.add('ctl:${req.uri.path}');
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>ctl</p></body></html>');
      await res.close();
    });

    log('https origins ${ports.join(",")} on $originHost, '
        'connect proxies ${proxies.map((p) => p.port).join(",")}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    for (var f = 0; f < proxies.length; f++) {
      log('proxy$f connects=${proxies[f].targets}');
    }
    log('socks-control connects=${controlSocks.targets}');
    log('verdict: containers=$containers, first-frame-socks-control=$control, '
        '${verdict.join(", ")}');
    await controlSocks.close();
    await controlOrigin.close(force: true);
    for (final p in proxies) {
      await p.close();
    }
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

  int? proxyThatSaw(String target) {
    for (var f = 0; f < proxies.length; f++) {
      if (proxies[f].targets.contains(target)) return f;
    }
    return null;
  }

  testWidgets('three stores, three CONNECT proxies, https origins',
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
                key: ValueKey('connecths$i'),
                initialUrlRequest: inapp.URLRequest(
                  url: inapp.WebUri('https://$originHost:${ports[i]}/c$i'),
                ),
                initialSettings: inapp.InAppWebViewSettings(
                  containerId: 'ws-proxy-connect-https-$i',
                  proxySettings: inapp.ProxySettings(
                    proxyRules: [
                      inapp.ProxyRule(
                        url: 'http://127.0.0.1:${proxies[i].port}',
                      ),
                    ],
                    bypassRules: [],
                  ),
                ),
                // The origin certificate is self-signed and minted for this
                // run, so the only way a load reaches it is to accept it
                // here. Scoped to this file; nothing else trusts it.
                onReceivedServerTrustAuthRequest: (controller, challenge) async =>
                    inapp.ServerTrustAuthResponse(
                  action: inapp.ServerTrustAuthResponseAction.PROCEED,
                ),
              ),
            ),
          SizedBox(
            width: 200,
            height: 90,
            child: inapp.InAppWebView(
              key: const ValueKey('socks-control'),
              initialUrlRequest: inapp.URLRequest(
                url: inapp.WebUri('http://$originHost:$controlPort/ctl'),
              ),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-connect-https-control',
                proxySettings: inapp.ProxySettings(
                  proxyRules: [
                    inapp.ProxyRule(
                      url: 'socks5://127.0.0.1:${controlSocks.port}',
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
        requests.contains('c$i:/c$i');

    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (List.generate(paneCount, settled).every((s) => s)) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });

    final results = <String>[];
    for (var i = 0; i < paneCount; i++) {
      final saw = proxyThatSaw('$originHost:${ports[i]}');
      results.add('c$i->${saw == i ? 'own(proxy$saw)' : saw != null ? 'CROSSED(proxy$saw)' : requests.contains('c$i:/c$i') ? 'DIRECT' : 'no load'}');
    }
    verdict.add('connect-https=[${results.join(" ")}]');
    final own = results.where((r) => r.contains('own(')).length;
    log('$own of $paneCount panes used their own CONNECT proxy');

    control = controlSocks.targets.contains('$originHost:$controlPort')
        ? 'proxied'
        : requests.contains('ctl:/ctl')
            ? 'DIRECT'
            : 'no load';
    log('first-frame socks control -> $control');
    expect(
      control,
      'proxied',
      reason: 'the SOCKS pane in this same first frame went $control, so this '
          'process proxied nothing and the CONNECT result below says nothing '
          'about CONNECT',
    );
    expect(
      own,
      paneCount,
      reason: 'three stores in the first frame, three distinct CONNECT '
          'proxies, https origins -- the arrangement WebKit tests upstream. '
          'Got [${results.join(" ")}]. Compare with proxy_http_connect, '
          'whose only difference is an http origin: if that one is all '
          'DIRECT with empty proxies and this one is not, the destination '
          'scheme is what decides whether a CONNECT proxy is used at all',
    );
  });
}
