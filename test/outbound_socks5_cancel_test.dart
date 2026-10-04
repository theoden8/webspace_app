// A SOCKS5 connect the client gave up on must not throw when the proxy
// answers afterwards.
//
// `HttpClient.close(force: true)` cancels every pending connection task: it
// destroys the task's socket once it arrives, swallowing its error, and then
// calls the task's `onCancel`. The SOCKS5 `onCancel` used to re-await the same
// connect future and `close()` it, with nothing listening to the result. A
// proxy that answered after the client closed (Tor's `ttlExpired` on an onion
// fetch the GeoIP downloader had timed out) then surfaced as an uncaught async
// error, which is how the macOS Tor scenario tier failed.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:socks5_proxy/exceptions.dart';
import 'package:webspace/services/outbound_http_io.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/proxy.dart';

/// Completes the SOCKS5 greeting, holds the CONNECT until [release], then
/// answers it with [replyCode] (0 succeeded, 6 TTL expired).
class _StallingSocks5 {
  _StallingSocks5._(this._server, this.replyCode) {
    _server.listen(_serve);
  }

  static Future<_StallingSocks5> bind(int replyCode) async => _StallingSocks5._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), replyCode);

  final ServerSocket _server;
  final int replyCode;
  final _connectSeen = Completer<void>();
  final _release = Completer<void>();
  final _clientGone = Completer<void>();
  final _clients = <Socket>[];

  int get port => _server.port;
  Future<void> get connectSeen => _connectSeen.future;

  /// Completes when the client side of the connection hangs up.
  Future<void> get clientGone => _clientGone.future;
  void release() => _release.complete();

  void _serve(Socket client) {
    _clients.add(client);
    var greeted = false;
    client.listen((bytes) async {
      if (!greeted) {
        greeted = true;
        client.add([5, 0]);
        return;
      }
      if (bytes.length > 1 && bytes[0] == 5 && bytes[1] == 1) {
        if (!_connectSeen.isCompleted) _connectSeen.complete();
        await _release.future;
        client.add([5, replyCode, 0, 1, 0, 0, 0, 0, 0, 0]);
      }
    }, onDone: _noteGone, onError: (Object e) {
      // A destroyed client can reach us as a reset rather than a FIN.
      if (e is! SocketException) throw e;
      _noteGone();
    }, cancelOnError: true);
  }

  void _noteGone() {
    if (!_clientGone.isCompleted) _clientGone.complete();
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _server.close();
  }
}

/// Starts a request through [proxy], closes the client while the proxy holds
/// the CONNECT, then lets the proxy answer. Returns every error that reached
/// the zone uncaught.
Future<List<Object>> _closeWhileConnecting(_StallingSocks5 proxy) async {
  final uncaught = <Object>[];
  await runZonedGuarded(() async {
    final result = const DefaultOutboundHttpFactory().clientFor(
      UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:${proxy.port}',
      ),
    );
    final client = (result as OutboundClientReady).client;
    final request = client
        .get(Uri.parse('http://example.invalid/'))
        .then<Object?>((r) => r)
        // Closing the client fails the request, and the request (not the
        // zone) is where that failure has to land: the refused connect as
        // itself, the granted one as a closed socket.
        .catchError((Object e) => e,
            test: (e) =>
                e is SocksClientException || e is http.ClientException)
        .timeout(const Duration(seconds: 2), onTimeout: () => null);
    await proxy.connectSeen;
    client.close();
    proxy.release();
    await request;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }, (error, _) => uncaught.add(error));
  return uncaught;
}

void main() {
  _StallingSocks5? proxy;

  tearDown(() async {
    await proxy?.close();
    proxy = null;
  });

  test('a connect the proxy refuses after the client closed stays caught',
      () async {
    final p = proxy = await _StallingSocks5.bind(6);
    expect(await _closeWhileConnecting(p), isEmpty);
  });

  test('a connect the proxy grants after the client closed stays caught',
      () async {
    final p = proxy = await _StallingSocks5.bind(0);
    expect(await _closeWhileConnecting(p), isEmpty);
    // The socket that arrived after the cancel is not left open.
    await p.clientGone.timeout(const Duration(seconds: 2));
  });

  test('a live client still reaches the origin through the proxy', () async {
    // The cancel path must not have broken the ordinary one: a request that
    // is not cancelled gets its CONNECT answered and reads the response.
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) => req.response
      ..write('ok')
      ..close());
    final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((client) async {
      var stage = 0;
      Socket? upstream;
      client.listen((bytes) async {
        if (stage == 0) {
          stage = 1;
          client.add([5, 0]);
        } else if (stage == 1) {
          stage = 2;
          upstream = await Socket.connect(InternetAddress.loopbackIPv4, origin.port);
          upstream!.listen(client.add, onDone: client.destroy);
          client.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
        } else {
          upstream!.add(bytes);
        }
      }, onDone: () => upstream?.destroy());
    });
    final client = (const DefaultOutboundHttpFactory().clientFor(
      UserProxySettings(type: ProxyType.SOCKS5, address: '127.0.0.1:${relay.port}'),
    ) as OutboundClientReady)
        .client;
    try {
      final res = await client
          .get(Uri.parse('http://localhost.test:${origin.port}/'))
          .timeout(const Duration(seconds: 5));
      expect(res.body, 'ok');
    } finally {
      client.close();
      await relay.close();
      await origin.close(force: true);
    }
  });
}
