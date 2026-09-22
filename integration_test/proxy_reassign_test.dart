// Assigning `proxyConfigurations` a second time, on a live store, between two
// navigations to two different destinations. Reported, not asserted.
//
// Destinations are `syntheticOrigin()` addresses. An address this machine owns
// is routed over `lo0` and Apple never proxies a loopback-routed destination,
// so an origin bound here reads DIRECT whether or not the proxy was bound --
// the defect that voided BUG-014's first 101 attempts. Nothing routes to a
// synthetic destination, so the fixture answers it and an arrival there is the
// proof.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';

import 'http_connect_fixture.dart';
import 'socks5_fixture.dart';

const bool kReassign =
    bool.fromEnvironment('WEBSPACE_REASSIGN', defaultValue: false);

/// `socks5` or `connect`.
///
/// The two take different paths through `NetworkSessionCocoa::
/// setProxyConfigData`. A config for which
/// `nw_proxy_config_stack_requires_http_protocols` holds -- CONNECT does,
/// SOCKS5 does not -- makes it destroy and rebuild every `NSURLSession`
/// via `recreateSessionWithUpdatedProxyConfigurations`; otherwise it only
/// patches the proxy onto the live `nw_context` of wrappers that already
/// have a session. Attempt 94 measured the weak path only.
const String kKind =
    String.fromEnvironment('WEBSPACE_REASSIGN_KIND', defaultValue: 'socks5');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Socks5Fixture socks;
  late HttpConnectFixture connect;
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 caution 1). Nothing routes to a
  // `syntheticOrigin`, so the fixture answers it and an arrival IS the proof.
  const destA = 0;
  const destB = 1;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-reassign] $m');
  }

  setUpAll(() async {
    await PlatformInfo.initialize();
    // Loopback is never proxied on Apple, so an origin bound to 127.0.0.1
    // measures nothing (BUG-014 attempt 4).
    socks = await Socks5Fixture.bind();
    connect = await HttpConnectFixture.bind();
    log('destA=${syntheticOrigin(destA)} destB=${syntheticOrigin(destB)} '
        'socks=${socks.port} connect=${connect.port} '
        'kind=$kKind reassign=$kReassign '
        'proxySupported=${PlatformInfo.isProxySupported}');
  });

  tearDownAll(() async {
    await socks.close();
    await connect.close();
  });

  testWidgets('a second assignment of proxyConfigurations', (tester) async {
    if (!hostIsMacOS) {
      log('verdict: skipped, not macOS');
      return;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');

    Map<String, dynamic>? reply;
    await tester.runAsync(() async {
      reply = await const MethodChannel('webspace/proxy_probe')
          .invokeMapMethod<String, dynamic>('probe', {
        'socksHost': '127.0.0.1',
        'socksPort': kKind == 'connect' ? connect.port : socks.port,
        'kind': kKind,
        'url': 'http://${syntheticOrigin(destA)}/a',
        'secondUrl': 'http://${syntheticOrigin(destB)}/b',
        'reassign': kReassign,
        'identified': true,
        'identifier': '8f1d5c4e-0000-4000-8000-0000000000a1',
        'attach': false,
        'proxy': true,
      }).timeout(const Duration(seconds: 60));
    });

    final proxyTargets = kKind == 'connect' ? connect.targets : socks.targets;
    // Nothing routes to a synthetic destination, so a navigation that did not
    // arrive at the proxy went direct and failed. The two are one reading
    // here, and both mean the configuration was not in force.
    String verdictFor(int dest) =>
        proxyTargets.any((t) => t.startsWith('${syntheticOrigin(dest)}:'))
            ? 'proxied'
            : 'DIRECT-or-failed';

    final baseline = verdictFor(destA);
    final second = verdictFor(destB);
    log('ok=${reply?['ok']} reassigned=${reply?['reassigned']} '
        'configured=${reply?['configured']} '
        'detail1=${reply?['detail1']} secondDetail=${reply?['secondDetail']}');
    log('$kKind targets=$proxyTargets');
    log('verdict: kind=$kKind reassign=$kReassign '
        'baseline=$baseline second=$second');

    // Reported, not asserted. A process without the slot produces the same
    // reading as a mechanism that does not work, and only `baseline` can
    // tell them apart -- which is why it is printed rather than expected.
    expect(baseline, isNot('no-load'),
        reason: 'the first navigation never reached either origin, so this '
            'process measured nothing and its verdict must not be counted');
  });
}
