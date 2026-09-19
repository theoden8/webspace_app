// The gate on the generator the https proxy arms depend on. The property
// those arms need is not that a certificate parses, it is that Dart's TLS
// stack serves it and a peer completes a handshake against it and gets the
// body back.
//
// Identity is checked through the certificate the peer is handed, not by
// letting the platform's trust policy decide. Apple's SSL policy refuses
// this certificate as a trust anchor where BoringSSL accepts it
// (CERTIFICATE_VERIFY_FAILED on the macOS tier), and nothing that uses this
// certificate asks the platform: the WebView panes answer
// onReceivedServerTrustAuthRequest with PROCEED, and the Dart-side clients
// pin by sha256. Asserting the trust policy was asserting something no
// caller relies on, on one platform only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/self_signed_cert.dart';

void main() {
  late SelfSignedCert cert;
  late HttpServer server;

  setUpAll(() {
    cert = generateSelfSignedCert(
      commonName: '127.0.0.1',
      ipAddresses: ['127.0.0.1'],
      dnsNames: ['localhost'],
    );
  });

  setUp(() async {
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      cert.serverContext(),
    );
    server.listen((req) async {
      final res = req.response..headers.contentType = ContentType.text;
      res.write('served ${req.uri.path}');
      await res.close();
    });
  });

  tearDown(() => server.close(force: true));

  Future<String> fetch(HttpClient client, String url) async {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    return res.transform(utf8.decoder).join();
  }

  test('the origin serves the certificate this run minted', () async {
    final presented = <List<int>>[];
    final client = HttpClient()
      ..badCertificateCallback = (c, host, port) {
        presented.add(c.der);
        return true;
      };
    addTearDown(() => client.close(force: true));

    expect(
      await fetch(client, 'https://127.0.0.1:${server.port}/by-ip'),
      'served /by-ip',
    );
    expect(
      presented.single,
      cert.certDer,
      reason: 'a handshake that completed against some other certificate '
          'would prove nothing about the one the arms serve',
    );
  });

  test('it answers on the name as well as the address', () async {
    final client = HttpClient()..badCertificateCallback = (c, h, p) => true;
    addTearDown(() => client.close(force: true));
    expect(
      await fetch(client, 'https://localhost:${server.port}/by-name'),
      'served /by-name',
    );
  });

  test('nothing trusts it on its own', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await expectLater(
      fetch(client, 'https://127.0.0.1:${server.port}/untrusted'),
      throwsA(isA<HandshakeException>()),
      reason: 'a self-signed certificate this run minted must not validate; '
          'if it did, the callers that accept it deliberately would be '
          'accepting anything',
    );
  });
}
