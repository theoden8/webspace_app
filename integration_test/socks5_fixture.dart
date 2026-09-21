// A SOCKS5 server the proxy tests point a WebView at, so "the proxy was
// used" is something the fixture observes rather than something inferred
// from a load that failed.
//
// A refused proxy only ever produces a negative assertion ("the origin was
// not reached"), which any broken load satisfies. This server records the
// destination of every CONNECT it is asked for and then relays, so a passing
// test has seen the request arrive *through* the proxy.

import 'dart:async';
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

/// An IPv4 address of this machine that is not loopback.
///
/// Apple's networking stack never sends a loopback destination through a
/// proxy: `localhost`, `127.0.0.1` and `::1` are always direct, and
/// `ProxyConfiguration` has no switch that changes it. A fixture origin on
/// `127.0.0.1` therefore loads directly whether or not the per-site proxy
/// was bound, which is exactly the defect these tests exist to catch.
Future<InternetAddress?> nonLoopbackIPv4() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address;
    }
  }
  return null;
}
