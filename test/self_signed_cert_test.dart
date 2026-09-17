// The gate on the generator the https proxy arms depend on. A certificate
// that parses is not the property those arms need; the property is that
// Dart's TLS stack serves it and a peer completes a handshake against its
// subjectAltName. Asserted both ways round, so a cert that is silently
// trusted by everything would fail too.

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

  HttpClient trusting() => HttpClient(
        context: SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(cert.certPem)),
      );

  Future<String> fetch(HttpClient client, String url) async {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    return res.transform(utf8.decoder).join();
  }

  test('a client trusting the cert reaches the origin by IP', () async {
    final client = trusting();
    addTearDown(() => client.close(force: true));
    expect(
      await fetch(client, 'https://127.0.0.1:${server.port}/by-ip'),
      'served /by-ip',
      reason: 'the iPAddress entry in the subjectAltName is what an Apple '
          'proxy arm connects through; a wrong encoding fails here',
    );
  });

  test('the dNSName entry matches too', () async {
    final client = trusting();
    addTearDown(() => client.close(force: true));
    expect(
      await fetch(client, 'https://localhost:${server.port}/by-name'),
      'served /by-name',
    );
  });

  test('nothing else trusts it', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await expectLater(
      fetch(client, 'https://127.0.0.1:${server.port}/untrusted'),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('a rejecting client can still opt in, which is what the panes do',
      () async {
    final client = HttpClient()..badCertificateCallback = (cert, host, port) => true;
    addTearDown(() => client.close(force: true));
    expect(
      await fetch(client, 'https://127.0.0.1:${server.port}/opt-in'),
      'served /opt-in',
    );
  });
}
