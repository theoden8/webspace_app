// The SOCKS5 fixture is an instrument, and an instrument that stops working
// partway through a run reads exactly like the defect it is pointed at.
//
// `integration_test/proxy_binding_test.dart` concluded from that fixture that
// only the first load a webview issues is proxied on Apple. That contradicts
// WebKit's source, which puts the proxy on the `NSURLSessionConfiguration`
// for every session wrapper, and it contradicts published testing of the same
// API, which found the leaks to be side channels outside normal page loading
// (DNS prefetch, WebAuthn, WebTransport) rather than "everything after the
// first request". When a measurement disagrees with both, the measurement is
// what to check.
//
// Every DIRECT reading in that file came later in the run than a proxied one.
// If the fixture stops accepting, or stops recording, after the first few
// connections, that alone produces the whole result. So: drive it with more
// sequential CONNECTs than the integration file ever makes, and assert it
// records and relays all of them.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/socks5_fixture.dart';

/// One SOCKS5 CONNECT through [proxyPort] to [host]:[port], returning the
/// body the origin served. Raw sockets rather than a package, so the test
/// exercises the fixture's own protocol handling.
Future<String> fetchThroughSocks({
  required int proxyPort,
  required String host,
  required int port,
  required String path,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
  socket.setOption(SocketOption.tcpNoDelay, true);
  final incoming = <int>[];
  final done = socket.listen(incoming.addAll).asFuture<void>();

  socket.add([5, 1, 0]); // greeting: version 5, one method, no auth
  await socket.flush();
  await Future<void>.delayed(const Duration(milliseconds: 50));

  final hostBytes = utf8.encode(host);
  socket.add(<int>[
    5, 1, 0, 3, // CONNECT, domain name
    hostBytes.length, ...hostBytes,
    (port >> 8) & 0xff, port & 0xff,
  ]);
  await socket.flush();
  await Future<void>.delayed(const Duration(milliseconds: 50));

  socket.add(utf8.encode('GET $path HTTP/1.1\r\nHost: $host:$port\r\n'
      'Connection: close\r\n\r\n'));
  await socket.flush();
  await done;
  return utf8.decode(Uint8List.fromList(incoming), allowMalformed: true);
}

void main() {
  late HttpServer origin;
  late Socks5Fixture socks;

  setUp(() async {
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      final res = req.response..headers.contentType = ContentType.text;
      res.write('served ${req.uri.path}');
      await res.close();
    });
    socks = await Socks5Fixture.bind();
  });

  tearDown(() async {
    await socks.close();
    await origin.close(force: true);
  });

  test('the fixture records and relays a long run of sequential CONNECTs',
      () async {
    // Ten is well past the six the integration file makes, and past the
    // point where every DIRECT reading in it occurred.
    const runs = 10;
    for (var i = 0; i < runs; i++) {
      final body = await fetchThroughSocks(
        proxyPort: socks.port,
        host: InternetAddress.loopbackIPv4.address,
        port: origin.port,
        path: '/load-$i',
      );
      expect(
        body,
        contains('served /load-$i'),
        reason: 'the fixture stopped relaying at connection $i, so every '
            'load after that point would read as unproxied no matter what '
            'the engine did',
      );
    }
    expect(socks.targets, hasLength(runs));
    for (var i = 0; i < runs; i++) {
      expect(socks.targets[i], '${InternetAddress.loopbackIPv4.address}:'
          '${origin.port}');
    }
  });

  test('the fixture serves connections that overlap', () async {
    // The integration file's first frame opens several at once, and a later
    // navigation opens another while earlier ones may still be held open by
    // keep-alive. A fixture that serialises would accept the first and stall
    // the rest, which reads as "the proxy was never asked".
    final bodies = await Future.wait([
      for (var i = 0; i < 5; i++)
        fetchThroughSocks(
          proxyPort: socks.port,
          host: InternetAddress.loopbackIPv4.address,
          port: origin.port,
          path: '/parallel-$i',
        ),
    ]);
    for (var i = 0; i < bodies.length; i++) {
      expect(bodies[i], contains('served /parallel-$i'));
    }
    expect(socks.targets, hasLength(5));
  });

  test('a CONNECT is recorded even when the destination refuses', () async {
    // The refused-proxy scenario depends on this: the target is recorded
    // before the upstream dial, so a destination that cannot be reached
    // still proves the proxy was the one asked.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close();

    await fetchThroughSocks(
      proxyPort: socks.port,
      host: InternetAddress.loopbackIPv4.address,
      port: deadPort,
      path: '/nowhere',
    );
    expect(socks.targets,
        contains('${InternetAddress.loopbackIPv4.address}:$deadPort'));
  });
}
