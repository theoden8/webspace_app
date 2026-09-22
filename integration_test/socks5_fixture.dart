// A SOCKS5 server the proxy tests point a WebView at, so "the proxy was
// used" is something the fixture observes rather than something inferred
// from a load that failed.
//
// A refused proxy only ever produces a negative assertion ("the origin was
// not reached"), which any broken load satisfies. This server records the
// destination of every CONNECT it is asked for and then relays, so a passing
// test has seen the request arrive *through* the proxy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fixture_server.dart';
import 'socket_relay.dart';

/// Byte-oriented view of a socket: `read(n)` completes once n bytes have
/// arrived, and [drain] hands back whatever was buffered past the handshake
/// so the relay can forward it.
class _ByteBuffer {
  final _bytes = <int>[];
  Completer<void>? _waiter;
  bool _closed = false;

  void add(List<int> data) {
    _bytes.addAll(data);
    _wake();
  }

  void close() {
    _closed = true;
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  Future<List<int>?> read(int n) async {
    while (_bytes.length < n) {
      if (_closed) return null;
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = _bytes.sublist(0, n);
    _bytes.removeRange(0, n);
    return out;
  }

  List<int> drain() {
    final out = List<int>.of(_bytes);
    _bytes.clear();
    return out;
  }
}

/// Minimal SOCKS5 (RFC 1928) server, no authentication, CONNECT only.
class Socks5Fixture {
  Socks5Fixture._(this._server);

  final ServerSocket _server;
  final _clients = <Socket>[];
  final _upstreams = <Socket>[];
  StreamSubscription<Socket>? _accepting;

  /// `host:port` of every CONNECT this server was asked for, in order.
  /// Recorded before the upstream connection is attempted, so a target that
  /// cannot be reached still shows that the proxy was the one asked.
  final targets = <String>[];

  /// Local port of every upstream socket this server dialled, which is the
  /// port the origin sees as its peer for anything relayed through here.
  ///
  /// Counting CONNECTs cannot tell a second request that reused a persistent
  /// connection from one that bypassed the proxy: both add no entry to
  /// [targets]. An origin that records `connectionInfo.remotePort` per
  /// request and matches it against this set attributes each request
  /// individually, reuse included.
  final relayedPorts = <int>{};

  /// Every synthetic destination this server answered itself, in order.
  ///
  /// Distinct from [targets], which also holds destinations that were
  /// relayed: a synthetic hit is proof the proxy carried the request, with
  /// no origin-side attribution needed.
  final servedSynthetic = <String>[];

  /// Every `<host><path>` a synthetic destination was asked for, in order.
  final syntheticPaths = <String>[];

  /// Body to answer a synthetic destination with, by destination host and
  /// request path. Null falls back to a plain marker page.
  ///
  /// An arm that needs the page to do something -- navigate itself away, say
  /// -- supplies it here, because a synthetic destination has no origin
  /// server behind it to serve from.
  String? Function(String host, String path)? syntheticBody;

  /// Certificate to answer a synthetic destination's TLS handshake with.
  ///
  /// Nothing routes to a synthetic destination, so for an `https://` arm the
  /// fixture is the only thing that can terminate the connection: it
  /// completes the SOCKS reply, secures its own client socket with this
  /// context, and serves the request inside. Null leaves it plaintext.
  SecurityContext? syntheticTls;

  int get port => _server.port;

  static Future<Socks5Fixture> bind() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = Socks5Fixture._(server);
    // Through the shared helper: an error on this socket is otherwise an
    // uncaught async error, which flutter_test reports against whichever
    // test finished last -- here, "(setUpAll) failed after test completion",
    // counted as a failure of its own.
    fixture._accepting = listenFixture(server, fixture._serve);
    return fixture;
  }

  Future<void> close() async {
    // Cancel before closing: a connection accepted between the two arrives
    // on a subscription whose error handler has already gone, and surfaces
    // as "(setUpAll) failed after test completion" against whichever test
    // finished last. The onError on the subscription alone did not cover it.
    await _accepting?.cancel();
    _accepting = null;
    for (final client in _clients) {
      client.destroy();
    }
    _clients.clear();
    for (final upstream in _upstreams) {
      upstream.destroy();
    }
    _upstreams.clear();
    await _server.close();
  }

  Future<void> _serve(Socket client) async {
    _clients.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    final buffer = _ByteBuffer();
    final incoming = client.listen(
      buffer.add,
      onError: (Object _) => buffer.close(),
      onDone: buffer.close,
    );
    // A socket whose peer vanishes reports it on `done`, and nothing else
    // here awaits that; unawaited it is an uncaught async error, which
    // `flutter_test` charges to whichever test finished last.
    unawaited(client.done.catchError((Object _) => client));
    Socket? upstream;
    try {
      final greeting = await buffer.read(2);
      if (greeting == null || greeting[0] != 5) return;
      if (await buffer.read(greeting[1]) == null) return;
      client.add(const [5, 0]);

      final head = await buffer.read(4);
      if (head == null) return;
      if (head[1] != 1) {
        client.add(const [5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
        return;
      }
      final host = await _readHost(buffer, head[3]);
      if (host == null) {
        client.add(const [5, 8, 0, 1, 0, 0, 0, 0, 0, 0]);
        return;
      }
      final rawPort = await buffer.read(2);
      if (rawPort == null) return;
      final destPort = (rawPort[0] << 8) | rawPort[1];
      targets.add('$host:$destPort');

      // A destination inside the reserved block is answered here rather than
      // relayed. See [syntheticOrigin]: nothing routes to it, so a request
      // that arrives proves the proxy carried it, and a bypassed request
      // cannot reach it by any other path.
      if (isSyntheticOrigin(host)) {
        servedSynthetic.add('$host:$destPort');
        client.add(const [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        await client.flush();

        /// Reads one request line and answers it, over whichever socket the
        /// connection ended up on.
        Future<void> answer(Socket sink, Future<List<int>?> Function() read) async {
          final head = <int>[];
          while (!String.fromCharCodes(head).contains('\r\n')) {
            final next = await read();
            if (next == null) break;
            head.addAll(next);
          }
          final path = RegExp(r'^\S+ (\S+)')
                  .firstMatch(String.fromCharCodes(head))
                  ?.group(1) ??
              '/';
          syntheticPaths.add('$host$path');
          final body = syntheticBody?.call(host, path) ??
              '<!doctype html><html><body><p>$host</p></body></html>';
          sink.add(const AsciiEncoder().convert('HTTP/1.1 200 OK\r\n'
              'Content-Type: text/html\r\n'
              'Connection: close\r\n'
              'Content-Length: '));
          sink.add(const AsciiEncoder().convert('${body.length}\r\n\r\n$body'));
          await sink.flush();
        }

        final tls = syntheticTls;
        if (tls != null) {
          // The ClientHello only follows the SOCKS reply, so it normally
          // lands after this cancel; `drain` covers the case where it beat
          // us, since those bytes are already off the socket.
          await incoming.cancel();
          final secure = await SecureSocket.secureServer(client, tls,
              bufferedData: buffer.drain());
          final inner = _ByteBuffer();
          final reading = secure.listen(inner.add,
              onError: (Object _) => inner.close(), onDone: inner.close);
          await answer(secure, () => inner.read(1));
          await reading.cancel();
          await secure.close();
          return;
        }
        await answer(client, () => buffer.read(1));
        await client.close();
        return;
      }

      upstream =
          await Socket.connect(host, destPort, timeout: const Duration(seconds: 5));
      _upstreams.add(upstream);
      relayedPorts.add(upstream.port);
      upstream.setOption(SocketOption.tcpNoDelay, true);
      unawaited(upstream.done.catchError((Object _) => upstream!));
      client.add(const [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);

      final pending = buffer.drain();
      await relaySockets(client, incoming, upstream, pending: pending);
    } on Object {
      client.destroy();
      upstream?.destroy();
    }
  }

  static Future<String?> _readHost(_ByteBuffer buffer, int addressType) async {
    if (addressType == 1) {
      final raw = await buffer.read(4);
      return raw?.join('.');
    }
    if (addressType == 3) {
      final length = await buffer.read(1);
      if (length == null) return null;
      final raw = await buffer.read(length[0]);
      return raw == null ? null : String.fromCharCodes(raw);
    }
    if (addressType == 4) {
      final raw = await buffer.read(16);
      if (raw == null) return null;
      return InternetAddress.fromRawAddress(
        Uint8List.fromList(raw),
        type: InternetAddressType.IPv6,
      ).address;
    }
    return null;
  }
}

/// A destination that is reachable only through a proxy fixture.
///
/// Apple never sends a *loopback-routed* destination through a proxy, and
/// "loopback-routed" is broader than `127.0.0.1`: macOS routes traffic aimed
/// at any address the host itself owns over `lo0`. The machine's own LAN
/// address is therefore just as unproxyable, which is what every proxy arm
/// used to point its origins at and what voided BUG-014's first 101 attempts.
/// Measured in one process, interleaved, with only the destination varying:
///
///     rung0[host-own-IP]=DIRECT  rung1[other-host-same-/24]=own
///     rung2[off-subnet]=own      rung3[host-own-IP]=DIRECT
///
/// Nothing routes to this block, so [Socks5Fixture] and [HttpConnectFixture]
/// answer it themselves instead of relaying: a request arriving at a fixture
/// IS the proof the proxy carried it, with no origin-side port attribution
/// and no second machine, and a bypassed request cannot arrive by accident.
String syntheticOrigin(int index) => '10.99.99.${index + 1}';

/// Whether [host] is one of [syntheticOrigin]'s destinations.
bool isSyntheticOrigin(String host) => host.startsWith('10.99.99.');
