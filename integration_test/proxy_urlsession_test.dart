// Is it WebKit, or the layer underneath it? (BUG-014)
//
// Every arm in this investigation has asked WKWebView and inferred the rest.
// `proxyConfigurations` is the same Network.framework type on
// `URLSessionConfiguration` as on `WKWebsiteDataStore`, and a `URLSession`
// runs in the app's own process, where the native side can trace every step
// instead of guessing from whether a fixture saw a CONNECT.
//
// Same proxy, same origin, two sequential loads:
//
//  * both reach the fixture -> the second-load failure is WebKit's, and the
//    layer under it is fine. That is what to report upstream.
//  * only the first reaches it -> `ProxyConfiguration` itself stops applying,
//    WebKit is blameless, and every WKWebView reading here was measuring the
//    wrong component.
//
// The native side disables the URL cache and forces
// `reloadIgnoringLocalAndRemoteCacheData`, so a repeated GET cannot be
// answered without a connection and read as a skipped proxy.

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
  final requests = <String>[];
  InternetAddress? routable;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-urlsession] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();
    origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    listenFixture(origin, (req) async {
      requests.add(req.uri.path);
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

  testWidgets('two sequential URLSession loads through one proxy config',
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
        'urlSessionSequential',
        {
          'socksHost': '127.0.0.1',
          'socksPort': socks.port,
          // Same URL twice on purpose: nothing about the request can differ
          // between the loads, so wrapper or domain routing cannot explain a
          // split.
          'urls': ['http://$target/a', 'http://$target/a'],
        },
      );
    });

    final connects = socks.targets.where((t) => t == target).length;
    log('reply=$reply');
    log('socks CONNECTs for $target = $connects, origin saw $requests');

    expect(reply, isNotNull, reason: 'the probe plugin did not answer');
    expect(reply!['ok'], isTrue,
        reason: 'the probe refused: ${reply!['detail']}');

    // Reported, not asserted on the split: which way it goes is the finding.
    // What IS asserted is that the arm ran at all -- two loads settled and
    // the fixture was reachable -- so a silent no-op cannot read as evidence.
    final outcomes = (reply!['outcomes'] as List?) ?? const [];
    expect(outcomes.length, 2,
        reason: 'both loads must settle for the comparison to mean anything, '
            'got $outcomes');
    expect(connects, greaterThan(0),
        reason: 'the first URLSession load did not reach the proxy fixture '
            'either, so this process could not proxy at all and the split '
            'below says nothing');

    log('VERDICT urlsession-sequential connects=$connects of 2 '
        'outcomes=$outcomes configuredAfter=${reply!['configuredAfter']}');
  });
}
