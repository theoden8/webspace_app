// An HTTP CONNECT proxy, the counterpart to `socks5_fixture.dart`.
//
// Why a second kind of proxy fixture, when one already records CONNECTs:
// WebKit installs a data store's proxy in one of two ways and the choice is
// not the caller's. `NetworkSessionCocoa::setProxyConfigData` asks
// `nw_proxy_config_stack_requires_http_protocols` about each configuration;
// if any says yes it destroys and rebuilds every NSURLSession with the
// proxy on that session's own `NSURLSessionConfiguration`
// (`SessionWrapper::recreateSessionWithUpdatedProxyConfigurations`), which
// is per-session and durable. If none does, it instead patches the live
// `nw_context` -- clearing the context's proxies first, and de-duplicating
// contexts across session wrappers, which it would not need to do unless
// they were shared.
//
// A SOCKS5 proxy takes the patching path. An HTTP CONNECT proxy is the only
// way to ask for the other one from outside WebKit, so it is how "the
// fragile path is why two stores cannot hold two proxies" gets tested
// rather than argued.
//
// Same contract as the SOCKS5 fixture: the destination of every CONNECT is
// recorded *before* the upstream is dialled, so a destination that cannot
// be reached still shows the proxy was the one asked.

import 'dart:async';
import 'dart:io';

import 'fixture_server.dart';
import 'socket_relay.dart';

class HttpConnectFixture {
  HttpConnectFixture._(this._server);

  final ServerSocket _server;
  final _clients = <Socket>[];
  final _upstreams = <Socket>[];
  StreamSubscription<Socket>? _accepting;

  /// `host:port` of every CONNECT this proxy was asked for, in order.
  final targets = <String>[];

  /// Local port of every upstream socket this proxy dialled, which is the
  /// port the origin sees as its peer for anything relayed through here.
  /// Lets an origin attribute each request individually instead of comparing
  /// CONNECT counts, which cannot see a reused persistent connection.
  final relayedPorts = <int>{};

  /// When set, a CONNECT without a matching `Proxy-Authorization` is answered
  /// `407` with a `Proxy-Authenticate: Basic` challenge instead of being
  /// tunnelled (BUG-014 route 2). WebKit bug 264309 says the header is never
  /// sent for a proxy configured through `proxyConfigurations`, not even
  /// after a 407; it does not say whether the 407 reaches the navigation
  /// delegate as an auth challenge, and those have opposite consequences for
  /// the relay design. This is the half of that question the fixture can
  /// answer.
  String? requiredCredential;

  /// How many `407`s this proxy sent, and every credential it was given.
  var challenges = 0;
  final credentials = <String>[];

  int get port => _server.port;

  static Future<HttpConnectFixture> bind() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = HttpConnectFixture._(server);
    fixture._accepting = listenFixture(server, fixture._serve);
    return fixture;
  }

  Future<void> close() async {
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
    final header = _HeaderBuffer();
    final incoming = client.listen(
      header.add,
      onError: (Object _) => header.close(),
      onDone: header.close,
    );
    // Unawaited `done` on a socket whose peer vanishes is an uncaught async
    // error, which `flutter_test` charges to whichever test finished last.
    unawaited(client.done.catchError((Object _) => client));
    Socket? upstream;
    try {
      final request = await header.readHeader();
      if (request == null) return;
      final parsed = _parseHead(request.head);
      if (parsed == null) {
        client.add('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits);
        return;
      }
      targets.add('${parsed.host}:${parsed.port}');

      final required = requiredCredential;
      if (required != null) {
        final offered = _proxyAuthorization(request.head);
        if (offered != null) credentials.add(offered);
        if (offered != required) {
          challenges++;
          client.add(('HTTP/1.1 407 Proxy Authentication Required\r\n'
                  'Proxy-Authenticate: Basic realm="webspace-relay"\r\n'
                  'Content-Length: 0\r\n'
                  'Proxy-Connection: keep-alive\r\n\r\n')
              .codeUnits);
          return;
        }
      }

      upstream = await Socket.connect(
        parsed.host,
        parsed.port,
        timeout: const Duration(seconds: 5),
      );
      _upstreams.add(upstream);
      relayedPorts.add(upstream.port);
      upstream.setOption(SocketOption.tcpNoDelay, true);
      unawaited(upstream.done.catchError((Object _) => upstream!));

      if (parsed.tunnel) {
        client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
        await relaySockets(client, incoming, upstream, pending: request.rest);
      } else {
        // Forward-proxy form. `nw_proxy_config` is a transport-level proxy
        // and should tunnel every scheme, but if it ever hands over an
        // absolute-URI request instead, dropping it would look exactly like
        // a proxy that was never asked -- which is the failure mode this
        // whole investigation keeps producing.
        upstream.add(parsed.forwarded!.codeUnits);
        await relaySockets(client, incoming, upstream, pending: request.rest);
      }
    } on Object {
      client.destroy();
      upstream?.destroy();
    }
  }

  /// The `Proxy-Authorization` value a request head carries, if any.
  static String? _proxyAuthorization(String head) {
    for (final line in head.split('\r\n').skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      if (line.substring(0, colon).toLowerCase() != 'proxy-authorization') {
        continue;
      }
      return line.substring(colon + 1).trim();
    }
    return null;
  }

  /// Either `CONNECT host:port HTTP/1.1` (tunnel) or an absolute-URI
  /// request line such as `GET http://host:port/p HTTP/1.1` (forward
  /// proxy). Both name a destination, which is all the recording needs;
  /// [forwarded] carries the head rewritten to origin form for the second.
  static ({String host, int port, bool tunnel, String? forwarded})? _parseHead(
    String head,
  ) {
    final lines = head.split('\r\n');
    final parts = lines.first.split(' ');
    if (parts.length < 3) return null;
    final method = parts[0].toUpperCase();

    if (method == 'CONNECT') {
      final colon = parts[1].lastIndexOf(':');
      if (colon <= 0) return null;
      final port = int.tryParse(parts[1].substring(colon + 1));
      if (port == null) return null;
      return (
        host: parts[1].substring(0, colon),
        port: port,
        tunnel: true,
        forwarded: null,
      );
    }

    final uri = Uri.tryParse(parts[1]);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final originForm = uri.path.isEmpty ? '/' : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final rewritten = <String>[
      '$method $originForm$query ${parts[2]}',
      ...lines.skip(1),
    ].join('\r\n');
    return (
      host: uri.host,
      port: port,
      tunnel: false,
      forwarded: '$rewritten\r\n\r\n',
    );
  }
}

/// Accumulates bytes until the end of the request head, handing back
/// whatever arrived after it so the relay can forward it.
class _HeaderBuffer {
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

  Future<({String head, List<int> rest})?> readHeader() async {
    while (true) {
      final end = _endOfHead();
      if (end != null) {
        final head = String.fromCharCodes(_bytes.sublist(0, end));
        final rest = List<int>.of(_bytes.sublist(end + 4));
        _bytes.clear();
        return (head: head, rest: rest);
      }
      if (_closed) return null;
      // A client that sends no head at all would otherwise hold the
      // fixture open for the life of the run.
      if (_bytes.length > 64 * 1024) return null;
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  int? _endOfHead() {
    for (var i = 0; i + 3 < _bytes.length; i++) {
      if (_bytes[i] == 13 &&
          _bytes[i + 1] == 10 &&
          _bytes[i + 2] == 13 &&
          _bytes[i + 3] == 10) {
        return i;
      }
    }
    return null;
  }
}
