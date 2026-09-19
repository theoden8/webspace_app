// The relay is the piece that would carry every per-site proxy on Apple, so
// the leak properties matter more than the routing ones and are asserted
// first: a tunnel it cannot attribute, and a tunnel whose upstream it cannot
// reach, must both be refused rather than dialled directly (LEAK-003). A
// direct dial here is the device IP reaching the origin the user picked a
// proxy to hide it from, and it would look exactly like success.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/local_proxy_relay.dart';
import 'package:webspace/settings/proxy.dart';

import '../integration_test/self_signed_cert.dart';
import '../integration_test/socks5_fixture.dart';

/// One CONNECT through the relay, optionally presenting a credential.
/// Returns everything the relay sent back, so the caller can tell a 200 from
/// a 407 from a 502.
Future<String> connectThroughRelay({
  required String host,
  required int port,
  required String targetHost,
  required int targetPort,
  String? username,
  String? token,
  String request = '',
}) async {
  final socket = await Socket.connect(host, port);
  socket.setOption(SocketOption.tcpNoDelay, true);
  final seen = <int>[];
  final done = socket.listen(seen.addAll).asFuture<void>();

  final auth = username == null
      ? ''
      : 'Proxy-Authorization: Basic '
          '${base64.encode(utf8.encode('$username:${token ?? ''}'))}\r\n';
  socket.add(utf8.encode('CONNECT $targetHost:$targetPort HTTP/1.1\r\n'
      'Host: $targetHost:$targetPort\r\n$auth\r\n'));
  await socket.flush();
  if (request.isNotEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    socket.add(utf8.encode(request));
    await socket.flush();
  }
  await done.timeout(
    const Duration(seconds: 6),
    onTimeout: () => socket.destroy(),
  );
  return String.fromCharCodes(seen);
}

void main() {
  late HttpServer origin;
  late LocalProxyRelay relay;
  late String originHost;

  setUp(() async {
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    originHost = InternetAddress.loopbackIPv4.address;
    origin.listen((req) async {
      final res = req.response..headers.contentType = ContentType.text;
      res.write('served ${req.uri.path}');
      await res.close();
    });
    relay = LocalProxyRelay(realm: 'webspace-test');
    expect(await relay.start(), isTrue);
  });

  tearDown(() async {
    await relay.stop();
    await origin.close(force: true);
  });

  String get(String path) => 'GET $path HTTP/1.1\r\nHost: $originHost\r\n'
      'Connection: close\r\n\r\n';

  test('a tunnel with no credential is challenged, not relayed', () async {
    relay.setRoutes({});
    final reply = await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
    );
    expect(reply, contains('407'));
    expect(reply, contains('realm="webspace-test"'));
    expect(
      reply,
      isNot(contains('200')),
      reason: 'an unattributable tunnel has no site, so it has no proxy; '
          'relaying it would be a direct fetch',
    );
  });

  test('a credential the relay does not know is challenged', () async {
    relay.setRoutes({
      'ws-site-a': LocalProxyRoute(
        siteId: 'site-a',
        token: 'token-a',
        upstream: UserProxySettings(type: ProxyType.DEFAULT),
      ),
    });
    final reply = await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
      username: 'ws-site-unknown',
      token: 'token-a',
    );
    expect(reply, contains('407'));
  });

  test('the right username with the wrong token is challenged', () async {
    relay.setRoutes({
      'ws-site-a': LocalProxyRoute(
        siteId: 'site-a',
        token: 'token-a',
        upstream: UserProxySettings(type: ProxyType.DEFAULT),
      ),
    });
    final reply = await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
      username: 'ws-site-a',
      token: 'token-b',
    );
    expect(
      reply,
      contains('407'),
      reason: 'the token is what stops one site presenting another site name '
          'and taking its circuit',
    );
  });

  test('a known credential on a direct route tunnels to the origin', () async {
    relay.setRoutes({
      'ws-site-a': LocalProxyRoute(
        siteId: 'site-a',
        token: 'token-a',
        upstream: UserProxySettings(type: ProxyType.DEFAULT),
      ),
    });
    final reply = await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
      username: 'ws-site-a',
      token: 'token-a',
      request: get('/direct'),
    );
    expect(reply, contains('200 Connection Established'));
    expect(reply, contains('served /direct'));
  });

  test('a SOCKS5 route reaches the origin through the SOCKS server', () async {
    final socks = await Socks5Fixture.bind();
    addTearDown(socks.close);
    relay.setRoutes({
      'ws-site-tor': LocalProxyRoute(
        siteId: 'site-tor',
        token: 'token-tor',
        upstream: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '${InternetAddress.loopbackIPv4.address}:${socks.port}',
        ),
      ),
    });

    final reply = await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
      username: 'ws-site-tor',
      token: 'token-tor',
      request: get('/through-socks'),
    );
    expect(reply, contains('200 Connection Established'));
    expect(reply, contains('served /through-socks'));
    expect(
      socks.targets,
      contains('$originHost:${origin.port}'),
      reason: 'the SOCKS server must have been the one asked for the origin, '
          'or the relay reached it directly',
    );
  });

  test('an unreachable upstream refuses rather than going direct', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close();

    relay.setRoutes({
      'ws-site-a': LocalProxyRoute(
        siteId: 'site-a',
        token: 'token-a',
        upstream: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '${InternetAddress.loopbackIPv4.address}:$deadPort',
        ),
      ),
    });

    final reply = await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
      username: 'ws-site-a',
      token: 'token-a',
      request: get('/should-not-arrive'),
    );
    expect(reply, contains('502'));
    expect(
      reply,
      isNot(contains('served /should-not-arrive')),
      reason: 'falling back to a direct dial when the site proxy is down is '
          'the leak this whole relay exists to avoid',
    );
  });

  test('two sites on two upstreams stay on their own', () async {
    final socksA = await Socks5Fixture.bind();
    final socksB = await Socks5Fixture.bind();
    addTearDown(socksA.close);
    addTearDown(socksB.close);
    relay.setRoutes({
      'ws-a': LocalProxyRoute(
        siteId: 'a',
        token: 'ta',
        upstream: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '${InternetAddress.loopbackIPv4.address}:${socksA.port}',
        ),
      ),
      'ws-b': LocalProxyRoute(
        siteId: 'b',
        token: 'tb',
        upstream: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '${InternetAddress.loopbackIPv4.address}:${socksB.port}',
        ),
      ),
    });

    await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
      username: 'ws-a',
      token: 'ta',
      request: get('/a'),
    );
    await connectThroughRelay(
      host: relay.host!,
      port: relay.port!,
      targetHost: originHost,
      targetPort: origin.port,
      username: 'ws-b',
      token: 'tb',
      request: get('/b'),
    );

    // The whole point of the relay: one endpoint, two circuits, no crossing.
    expect(socksA.targets, hasLength(1));
    expect(socksB.targets, hasLength(1));
  });

  // What the goal arm actually asks of the relay: WebKit CONNECTs, then runs
  // its own TLS handshake with the origin through the tunnel. The relay is a
  // byte pipe past the 200, so this should hold -- but if it did not, the arm
  // would come back "no load" and read as WebKit having ignored the proxy,
  // which is the reading this whole bug keeps being misled by.
  test('a tunnel carries a TLS session end to end', () async {
    final cert = generateSelfSignedCert(
      commonName: '127.0.0.1',
      ipAddresses: ['127.0.0.1'],
    );
    final tls = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      cert.serverContext(),
    );
    addTearDown(() => tls.close(force: true));
    tls.listen((req) async {
      final res = req.response..headers.contentType = ContentType.text;
      res.write('tls ${req.uri.path}');
      await res.close();
    });

    final socks = await Socks5Fixture.bind();
    addTearDown(socks.close);
    relay.setRoutes({
      'ws-tls': LocalProxyRoute(
        siteId: 'tls',
        token: 'token-tls',
        upstream: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '${InternetAddress.loopbackIPv4.address}:${socks.port}',
        ),
      ),
    });

    // The origin certificate is checked by identity rather than by the
    // platform's trust policy: Apple refuses this one as an anchor where
    // BoringSSL accepts it, and what this test is about is the tunnel.
    final client = HttpClient()
      ..badCertificateCallback = ((c, host, port) => c.der.toString() ==
          cert.certDer.toString())
      ..findProxy = (_) => 'PROXY ${relay.host}:${relay.port}';
    addTearDown(() => client.close(force: true));
    client.addProxyCredentials(
      relay.host!,
      relay.port!,
      'webspace-test',
      HttpClientBasicCredentials('ws-tls', 'token-tls'),
    );

    final res =
        await (await client.getUrl(Uri.parse('https://127.0.0.1:${tls.port}/t')))
            .close();
    expect(await res.transform(utf8.decoder).join(), 'tls /t');
    expect(
      socks.targets,
      contains('${InternetAddress.loopbackIPv4.address}:${tls.port}'),
      reason: 'the tunnelled TLS session must have been dialled by the '
          "site's upstream, not by the relay itself",
    );
  });

  // The client that matters here is WebKit, and a proxy credential supplied
  // through `applyCredential` may only be sent after a challenge. Closing the
  // connection on the 407 would turn "answer the challenge" into a dead load
  // -- which reads as the proxy having been ignored, not refused, and would
  // have been diagnosed as WebKit dropping the proxy.
  test('a challenged client may retry on the same connection', () async {
    relay.setRoutes({
      'ws-site-a': LocalProxyRoute(
        siteId: 'site-a',
        token: 'token-a',
        upstream: UserProxySettings(type: ProxyType.DEFAULT),
      ),
    });

    final socket = await Socket.connect(relay.host!, relay.port!);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final seen = <int>[];
    final done = socket.listen(seen.addAll).asFuture<void>();

    // First attempt carries no credential.
    socket.add(utf8.encode('CONNECT $originHost:${origin.port} HTTP/1.1\r\n'
        'Host: $originHost:${origin.port}\r\n\r\n'));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      String.fromCharCodes(seen),
      contains('407'),
      reason: 'the unauthenticated attempt must be challenged',
    );

    // Second attempt, same socket, now with the credential.
    final auth = base64.encode(utf8.encode('ws-site-a:token-a'));
    socket.add(utf8.encode('CONNECT $originHost:${origin.port} HTTP/1.1\r\n'
        'Host: $originHost:${origin.port}\r\n'
        'Proxy-Authorization: Basic $auth\r\n\r\n'));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    socket.add(utf8.encode(get('/after-challenge')));
    await socket.flush();

    await done.timeout(
      const Duration(seconds: 6),
      onTimeout: () => socket.destroy(),
    );
    final reply = String.fromCharCodes(seen);
    expect(reply, contains('200 Connection Established'));
    expect(reply, contains('served /after-challenge'));
  });
}
