// Does assigning `proxyConfigurations` a second time reopen the window?
//
// BUG-014, attempts 90 and 92: a per-site proxy on Apple covers the
// navigation issued in the turn that mounts the WebView, and the next one
// goes direct to the origin while the store still reports the proxy. Both
// readings carried a live control in their own process, so the shape is not
// in doubt. The mechanism was.
//
// WebKit's source names a candidate:
//
//   void WebsiteDataStore::setProxyConfigData(Vector<...>&& data)
//   {
//       m_proxyConfigData = std::nullopt;
//       protectedNetworkProcess()->send(
//         Messages::NetworkProcess::SetProxyConfigData(m_sessionID, data), 0);
//       m_proxyConfigData = WTFMove(data);
//   }
//
// `parameters()` builds a network session's configuration from that same
// `m_proxyConfigData`, so anything that reads it between the first and last
// line gets a session with no proxy. `protectedNetworkProcess()` is inside
// the window and launches the process when it is not already up.
//
// If that is what closes the window, then assigning the same configuration
// again -- at a point where the process is certainly up and the session
// certainly exists -- should install it, and the second navigation should be
// proxied. One store, one WebView, two navigations to two different origins,
// so the fixture attributes each by the port it was asked for and a reused
// connection cannot pass for a bypass (attempt 87's confound).
//
// Read the verdict as:
//
//   baseline=DIRECT   this process never had the slot; the run says nothing
//   baseline=proxied second=DIRECT    the bypass, reproduced
//   baseline=proxied second=proxied   re-assignment reopens the window
//
// The last line is the one that would turn BUG-014 from a WebKit wall into
// an ordering bug this app can fix in the fork. Run with and without
// --dart-define=WEBSPACE_REASSIGN, so the no-reassign run is the in-process
// control for the same shape rather than a comparison across runs.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';

import 'fixture_server.dart';
import 'socks5_fixture.dart';

const bool kReassign =
    bool.fromEnvironment('WEBSPACE_REASSIGN', defaultValue: false);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Socks5Fixture socks;
  late HttpServer originA;
  late HttpServer originB;
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  final requests = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-reassign] $m');
  }

  setUpAll(() async {
    await PlatformInfo.initialize();
    // Loopback is never proxied on Apple, so an origin bound to 127.0.0.1
    // measures nothing (BUG-014 attempt 4).
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();
    originA = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    originB = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    for (final entry in {'a': originA, 'b': originB}.entries) {
      listenFixture(entry.value, (req) async {
        requests.add('${entry.key}:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>${entry.key}</p></body></html>');
        await res.close();
      });
    }
    log('host=$originHost originA=${originA.port} originB=${originB.port} '
        'socks=${socks.port} reassign=$kReassign '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'routable=${routable != null}');
  });

  tearDownAll(() async {
    await socks.close();
    await originA.close(force: true);
    await originB.close(force: true);
  });

  testWidgets('a second assignment of proxyConfigurations', (tester) async {
    if (!hostIsMacOS) {
      log('verdict: skipped, not macOS');
      return;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback address: every origin would be exempt from '
            'the proxy and the run would measure nothing');
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');

    Map<String, dynamic>? reply;
    await tester.runAsync(() async {
      reply = await const MethodChannel('webspace/proxy_probe')
          .invokeMapMethod<String, dynamic>('probe', {
        'socksHost': '127.0.0.1',
        'socksPort': socks.port,
        'kind': 'socks5',
        'url': 'http://$originHost:${originA.port}/a',
        'secondUrl': 'http://$originHost:${originB.port}/b',
        'reassign': kReassign,
        'identified': true,
        'identifier': '8f1d5c4e-0000-4000-8000-0000000000a1',
        'attach': false,
        'proxy': true,
      }).timeout(const Duration(seconds: 60));
    });

    String verdictFor(int port) =>
        socks.targets.contains('$originHost:$port')
            ? 'proxied'
            : requests.any((r) => r.startsWith(port == originA.port ? 'a:' : 'b:'))
                ? 'DIRECT'
                : 'no-load';

    final baseline = verdictFor(originA.port);
    final second = verdictFor(originB.port);
    log('ok=${reply?['ok']} reassigned=${reply?['reassigned']} '
        'configured=${reply?['configured']} '
        'detail1=${reply?['detail1']} secondDetail=${reply?['secondDetail']}');
    log('socks targets=${socks.targets}');
    log('verdict: reassign=$kReassign baseline=$baseline second=$second');

    // Reported, not asserted. A process without the slot produces the same
    // reading as a mechanism that does not work, and only `baseline` can
    // tell them apart -- which is why it is printed rather than expected.
    expect(baseline, isNot('no-load'),
        reason: 'the first navigation never reached either origin, so this '
            'process measured nothing and its verdict must not be counted');
  });
}
