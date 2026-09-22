// The HTTP CONNECT fixture is an instrument, and this file exists because
// the SOCKS5 one shipped untested and spent three attempts of BUG-014 being
// trusted. Same three properties: a long sequential run, overlapping
// connections, and a recorded target for a destination that refuses.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/http_connect_fixture.dart';

/// One CONNECT tunnel through [proxyPort] to [host]:[port], then a plain
/// GET inside it. Raw sockets rather than a client package, so the test
/// exercises the fixture's own protocol handling.
Future<String> fetchThroughConnect({
  required int proxyPort,
  required String host,
  required int port,
  required String path,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
  socket.setOption(SocketOption.tcpNoDelay, true);
  final incoming = <int>[];
  final done = socket.listen(incoming.addAll).asFuture<void>();

  socket.add('CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n\r\n'
      .codeUnits);
  await socket.flush();
  await Future<void>.delayed(const Duration(milliseconds: 50));

  socket.add('GET $path HTTP/1.1\r\nHost: $host:$port\r\n'
      'Connection: close\r\n\r\n'
      .codeUnits);
  await socket.flush();

  await done.timeout(
    const Duration(seconds: 5),
    onTimeout: () => socket.destroy(),
  );
  return String.fromCharCodes(incoming);
}

void main() {
  late HttpServer origin;
  late HttpConnectFixture proxy;

  setUp(() async {
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      final res = req.response..headers.contentType = ContentType.text;
      res.write('served ${req.uri.path}');
      await res.close();
    });
    proxy = await HttpConnectFixture.bind();
  });

  tearDown(() async {
    await proxy.close();
    await origin.close(force: true);
  });

  test('the fixture records and relays a long run of sequential CONNECTs',
      () async {
    const runs = 10;
    for (var i = 0; i < runs; i++) {
      final body = await fetchThroughConnect(
        proxyPort: proxy.port,
        host: InternetAddress.loopbackIPv4.address,
        port: origin.port,
        path: '/load-$i',
      );
      expect(
        body,
        contains('200 Connection Established'),
        reason: 'connection $i was never tunnelled',
      );
      expect(
        body,
        contains('served /load-$i'),
        reason: 'the fixture stopped relaying at connection $i, so every '
            'load after that point would read as unproxied no matter what '
            'the engine did',
      );
    }
    expect(proxy.targets, hasLength(runs));
    for (var i = 0; i < runs; i++) {
      expect(
        proxy.targets[i],
        '${InternetAddress.loopbackIPv4.address}:${origin.port}',
      );
    }
  });

  test('the fixture serves connections that overlap', () async {
    final bodies = await Future.wait([
      for (var i = 0; i < 5; i++)
        fetchThroughConnect(
          proxyPort: proxy.port,
          host: InternetAddress.loopbackIPv4.address,
          port: origin.port,
          path: '/parallel-$i',
        ),
    ]);
    for (var i = 0; i < bodies.length; i++) {
      expect(bodies[i], contains('served /parallel-$i'));
    }
    expect(proxy.targets, hasLength(5));
  });

  test('a CONNECT is recorded even when the destination refuses', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close();

    await fetchThroughConnect(
      proxyPort: proxy.port,
      host: InternetAddress.loopbackIPv4.address,
      port: deadPort,
      path: '/nowhere',
    );
    expect(
      proxy.targets,
      contains('${InternetAddress.loopbackIPv4.address}:$deadPort'),
    );
  });

  // `nw_proxy_config` is transport-level and should always tunnel, but a
  // fixture that only understood CONNECT would record nothing if it ever
  // saw the forward-proxy form -- which reads identically to a proxy that
  // was never asked, the exact confusion this tier keeps producing.
  test('an absolute-URI request is recorded and forwarded too', () async {
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final incoming = <int>[];
    final done = socket.listen(incoming.addAll).asFuture<void>();
    final host = InternetAddress.loopbackIPv4.address;
    socket.add('GET http://$host:${origin.port}/forwarded HTTP/1.1\r\n'
            'Host: $host:${origin.port}\r\nConnection: close\r\n\r\n'
        .codeUnits);
    await socket.flush();
    await done.timeout(
      const Duration(seconds: 5),
      onTimeout: () => socket.destroy(),
    );

    expect(proxy.targets, contains('$host:${origin.port}'));
    expect(
      String.fromCharCodes(incoming),
      contains('served /forwarded'),
      reason: 'the forward-proxy form must be relayed, not dropped',
    );
  });
}
