// Is one proxied session per process the rule, or is the config object
// single-use? (BUG-014)
//
// `NetworkSessionCocoa::applyProxyConfigurationToSessionConfiguration` puts
// the same `nw_proxy_config_t` instances into every session configuration it
// touches, so "the object is consumed by whoever uses it first" is a shape
// WebKit's source permits. Nothing in this investigation has tested it, and
// it is not testable through `WKWebsiteDataStore` -- there the object is
// minted inside the network process, out of reach.
//
// Three `URLSession`s, one load each, same endpoint. Sessions 1 and 2 share
// one `ProxyConfiguration` instance; session 3 mints its own.
//
//  * 1 proxied, 2 direct, 3 proxied -> the object is single-use, and the app
//    fix is to mint one per store.
//  * 1 proxied, 2 and 3 direct -> one proxied session per process, which is
//    gap -2 reproduced in a place where it can be traced.
//  * all three proxied -> the layer under WebKit is sound here too, and the
//    second-load failure is WebKit's alone.
//
// Attribution is per request, by the peer port the origin saw against the
// ports the fixture dialled from (BUG-014 attempt 87), so a session that
// reuses a connection is still credited to the proxy that opened it.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'fixture_server.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('webspace/proxy_probe');
  final applies = hostIsMacOS;

  late HttpServer origin;
  late Socks5Fixture socks;
  late String originHost;
  final requests = <({String path, int port})>[];
  InternetAddress? routable;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-persession] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();
    origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    listenFixture(origin, (req) async {
      requests
          .add((path: req.uri.path, port: req.connectionInfo?.remotePort ?? -1));
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>o</p></body></html>');
      await res.close();
    });
    log('host $originHost origin ${origin.port} socks ${socks.port}');
  });

  tearDownAll(() async {
    if (!applies) return;
    await socks.close();
    await origin.close(force: true);
  });

  testWidgets('three URLSessions, one shared proxy object and one fresh',
      (tester) async {
    if (!applies) {
      markTestSkipped('the probe plugin is macOS only');
      return;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4 here, and Apple never proxies a '
            'loopback destination, so nothing could be distinguished');

    final target = '$originHost:${origin.port}';
    Map<Object?, Object?>? reply;
    await tester.runAsync(() async {
      reply = await channel.invokeMethod<Map<Object?, Object?>>(
        'urlSessionPerSession',
        {
          'socksHost': '127.0.0.1',
          'socksPort': socks.port,
          'url': 'http://$target/p',
        },
      );
    });

    expect(reply, isNotNull, reason: 'the probe plugin did not answer');
    expect(reply!['ok'], isTrue,
        reason: 'the probe refused: ${reply!['detail']}');

    final labels = (reply!['labels'] as List?)?.cast<Object?>() ?? const [];
    final outcomes = (reply!['outcomes'] as List?) ?? const [];
    // The loads are sequential and each session makes exactly one, so the
    // origin's arrivals line up with the labels in order. A session whose
    // load never arrived leaves a hole, which is itself a reading.
    final seen = <String>[];
    for (var i = 0; i < requests.length; i++) {
      final label = i < labels.length ? '${labels[i]}' : 'extra$i';
      seen.add(
          '$label:${socks.relayedPorts.contains(requests[i].port) ? "proxied" : "direct"}');
    }
    final proxied = seen.where((s) => s.endsWith(':proxied')).length;

    log('relayed ports ${socks.relayedPorts.toList()..sort()}, '
        'CONNECTs ${socks.targets}');

    expect(outcomes.length, 3,
        reason: 'all three loads must settle for the comparison to mean '
            'anything, got $outcomes');
    expect(proxied, greaterThan(0),
        reason: 'not even the first session reached the origin through the '
            'fixture, so this process could not proxy at all and the split '
            'below says nothing: $seen');

    log('VERDICT urlsession-persession proxied=$proxied of ${requests.length} '
        'arrivals=$seen outcomes=$outcomes');
  });
}
