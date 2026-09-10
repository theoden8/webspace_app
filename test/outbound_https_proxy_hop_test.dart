import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/outbound_http_io.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/settings/proxy.dart';

/// An `HTTPS`-type proxy is a TLS session to the proxy. `findProxy` alone
/// makes dart:io open a plain socket and write `CONNECT host:port` plus the
/// Basic credentials before any handshake, so every Dart-side fetch under
/// such a proxy used to put the proxy password and the destination host on
/// the wire in cleartext (LEAK-008). These tests stand up real sockets: a
/// plain listener that must only ever see a TLS ClientHello, and a TLS
/// CONNECT proxy in front of a TLS origin that must see the credentials and
/// still hand back the origin's body through the nested handshake.
int _indexOfHeadEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// Minimal CONNECT proxy: answers 407 until Basic credentials arrive, then
/// tunnels to [originPort]. Every request head it sees lands in [heads].
Future<SecureServerSocket> _startConnectProxy(
  SecurityContext ctx, {
  required int originPort,
  required List<String> heads,
}) async {
  final server = await SecureServerSocket.bind('127.0.0.1', 0, ctx);
  server.listen((client) {
    final buf = BytesBuilder();
    Socket? origin;
    var headDone = false;
    late StreamSubscription<Uint8List> sub;
    sub = client.listen((data) async {
      if (headDone) {
        origin?.add(data);
        return;
      }
      buf.add(data);
      final bytes = buf.toBytes();
      final end = _indexOfHeadEnd(bytes);
      if (end < 0) return;
      headDone = true;
      sub.pause();
      final head = latin1.decode(bytes.sublist(0, end));
      heads.add(head);
      if (!head.toLowerCase().contains('proxy-authorization: basic ')) {
        client.write('HTTP/1.1 407 Proxy Authentication Required\r\n'
            'Proxy-Authenticate: Basic realm="test"\r\n'
            'Content-Length: 0\r\nConnection: close\r\n\r\n');
        await client.flush();
        await client.close();
        return;
      }
      origin = await Socket.connect('127.0.0.1', originPort);
      origin!.listen(
        (d) => client.add(d),
        onDone: () => client.close(),
        onError: (_) => client.close(),
      );
      final rest = bytes.sublist(end + 4);
      if (rest.isNotEmpty) origin!.add(rest);
      client.write('HTTP/1.1 200 Connection established\r\n\r\n');
      await client.flush();
      sub.resume();
    }, onDone: () => origin?.close(), onError: (_) => origin?.close());
  });
  return server;
}

Future<({ServerSocket server, BytesBuilder seen})> _plainSink() async {
  final seen = BytesBuilder();
  final server = await ServerSocket.bind('127.0.0.1', 0);
  server.listen((s) {
    s.listen((d) {
      seen.add(d);
      s.destroy();
    });
  });
  return (server: server, seen: seen);
}

void main() {
  final haveOpenssl = () {
    try {
      return Process.runSync('openssl', ['version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();
  final skip = haveOpenssl ? null : 'openssl is not installed';

  late Directory dir;
  late SecurityContext ctx;
  late String fingerprint;
  const factory = DefaultOutboundHttpFactory();

  setUpAll(() async {
    if (!haveOpenssl) return;
    dir = await Directory.systemTemp.createTemp('webspace-tls-');
    final key = '${dir.path}/key.pem';
    final cert = '${dir.path}/cert.pem';
    final gen = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-keyout', key, '-out', cert, '-subj', '/CN=localhost',
      '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    ]);
    expect(gen.exitCode, 0, reason: gen.stderr.toString());
    final der = await Process.run(
      'openssl',
      ['x509', '-in', cert, '-outform', 'DER'],
      stdoutEncoding: null,
    );
    fingerprint = sha256.convert(der.stdout as List<int>).toString();
    ctx = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() async {
    if (haveOpenssl) await dir.delete(recursive: true);
  });

  test('an HTTPS-type proxy never receives plaintext (LEAK-008)', () async {
    final sink = await _plainSink();
    addTearDown(() => sink.server.close());
    final client = factory.clientFor(UserProxySettings(
      type: ProxyType.HTTPS,
      address: '127.0.0.1:${sink.server.port}',
      username: 'user',
      password: 'hunter2',
    )) as OutboundClientReady;
    await expectLater(
      client.client.get(Uri.parse('https://origin.test:1/secret')),
      throwsA(anything),
    );
    final bytes = sink.seen.toBytes();
    expect(bytes, isNotEmpty);
    expect(bytes.first, 0x16, reason: 'the first byte must open a TLS record');
    final text = latin1.decode(bytes);
    expect(text, isNot(contains('CONNECT')));
    expect(text, isNot(contains('origin.test')));
    expect(text, isNot(contains('Proxy-Authorization')));
    expect(text, isNot(contains('hunter2')));
  });

  test('an HTTP-type proxy still speaks plaintext, which is the contrast',
      () async {
    final sink = await _plainSink();
    addTearDown(() => sink.server.close());
    final client = factory.clientFor(UserProxySettings(
      type: ProxyType.HTTP,
      address: '127.0.0.1:${sink.server.port}',
    )) as OutboundClientReady;
    await expectLater(
      client.client.get(Uri.parse('https://origin.test:1/secret')),
      throwsA(anything),
    );
    expect(latin1.decode(sink.seen.toBytes()),
        startsWith('CONNECT origin.test:1'));
  });

  test(
      'CONNECT and the credentials travel inside TLS, and the origin\'s '
      'own TLS nests through the tunnel', () async {
    final origin = await HttpServer.bindSecure('127.0.0.1', 0, ctx);
    origin.listen((req) {
      req.response
        ..headers.contentType = ContentType.text
        ..write('hello from ${req.uri.path}')
        ..close();
    });
    addTearDown(() => origin.close(force: true));
    final heads = <String>[];
    final proxy =
        await _startConnectProxy(ctx, originPort: origin.port, heads: heads);
    addTearDown(() => proxy.close());

    final trusted = TrustedHostsService.instance;
    await trusted.trust(
        host: '127.0.0.1', port: proxy.port, fingerprint: fingerprint);
    await trusted.trust(
        host: 'origin.test', port: origin.port, fingerprint: fingerprint);
    addTearDown(() => trusted.clear());

    final client = factory.clientFor(UserProxySettings(
      type: ProxyType.HTTPS,
      address: '127.0.0.1:${proxy.port}',
      username: 'user',
      password: 'hunter2',
    )) as OutboundClientReady;
    final res = await client.client
        .get(Uri.parse('https://origin.test:${origin.port}/file.bin'))
        .timeout(const Duration(seconds: 10));
    expect(res.statusCode, 200);
    expect(res.body, 'hello from /file.bin');

    final authed = heads
        .where((h) => h.toLowerCase().contains('proxy-authorization: basic '))
        .toList();
    expect(authed, isNotEmpty, reason: 'the proxy never saw the credentials');
    expect(authed.first, startsWith('CONNECT origin.test:${origin.port}'));
    final basic = base64Encode(utf8.encode('user:hunter2'));
    expect(authed.first.toLowerCase(),
        contains('proxy-authorization: basic ${basic.toLowerCase()}'));
  }, skip: skip);
}
