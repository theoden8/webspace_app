import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/network_sign_in.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/outbound_http_io.dart'
    show DefaultOutboundHttpFactory;
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/settings/proxy.dart';

import '../integration_test/self_signed_cert.dart';

/// TLS-012 for the Dart-side clients: a pin is not honoured while the OS last
/// reported a captive portal, whose certificate answers in the host's place.
/// No TestWidgetsFlutterBinding: it stubs every HttpClient to answer 400.
void main() {
  late SelfSignedCert cert;
  late HttpServer server;
  late NetworkVerdict verdict;

  setUpAll(() => cert = generateSelfSignedCert(
      commonName: '127.0.0.1', ipAddresses: ['127.0.0.1']));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await TrustedHostsService.instance.clear();
    verdict = const NoSignIn();
    NetworkSignIn.instance = NetworkSignIn(read: () async => verdict);
    server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, cert.serverContext());
    server.listen((req) async {
      req.response.write('ok');
      await req.response.close();
    });
    await TrustedHostsService.instance.trust(
      host: '127.0.0.1',
      port: server.port,
      fingerprint: sha256.convert(cert.certDer).toString(),
    );
  });

  tearDown(() => server.close(force: true));

  Future<String> fetch() async {
    final client = (const DefaultOutboundHttpFactory().clientFor(
      OutboundProxy.ofApp(UserProxySettings(type: ProxyType.DEFAULT)).resolved,
    ) as OutboundClientReady)
        .client;
    try {
      final res = await client
          .get(Uri.parse('https://127.0.0.1:${server.port}/'))
          .timeout(const Duration(seconds: 5));
      return res.body;
    } on HandshakeException {
      return 'refused';
    } finally {
      client.close();
    }
  }

  test('TLS-012: a Dart client refuses a pin while the OS reports a portal, '
      'and honours it again once it clears (SEC-055)', () async {
    expect(await fetch(), 'ok', reason: 'no verdict read yet: honoured');

    verdict = SignInRequired(NetworkKey.android('100'));
    await NetworkSignIn.instance.verdict();
    expect(await fetch(), 'refused');

    verdict = const NoSignIn();
    await NetworkSignIn.instance.verdict();
    expect(await fetch(), 'ok');
  });
}
