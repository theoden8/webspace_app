import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:socks5_proxy/socks_client.dart' as socks5;
import 'package:webspace/settings/proxy.dart';

/// A loopback HTTP CONNECT proxy that fans one endpoint out to one upstream
/// per site.
///
/// The Apple counterpart to Android's `ProxyRelay` (PROXY-013), and for the
/// same reason: the platform carries one proxy well and several badly, so
/// every site's data store is pointed at *this* endpoint and the per-site
/// choice is made here instead. Two properties follow from that, and both
/// matter more than the routing:
///
///  * **HTTP CONNECT, not SOCKS5.** WebKit installs a store's proxy by one
///    of two routes and the caller does not choose:
///    `NetworkSessionCocoa::setProxyConfigData` rebuilds each NSURLSession
///    with the proxy on its own `NSURLSessionConfiguration` when
///    `nw_proxy_config_stack_requires_http_protocols` is true for any
///    configuration, and otherwise patches the live `nw_context` -- which it
///    clears first, and which it de-duplicates across session wrappers. A
///    SOCKS5 rule only ever takes the second. So the relay speaks CONNECT
///    even when every upstream behind it is SOCKS5.
///  * **Fail closed.** A tunnel this relay cannot attribute to a site, or
///    whose site names an upstream it cannot reach, is refused. It is never
///    relayed directly: a direct fetch here is the device IP reaching the
///    origin the user picked a proxy to hide it from (LEAK-003).
class LocalProxyRelay {
  LocalProxyRelay({required this.realm});

  /// Named in the `407`, so a challenge from anything else is ignorable.
  final String realm;

  ServerSocket? _server;
  StreamSubscription<Socket>? _accepting;
  final _clients = <Socket>[];
  final _upstreams = <Socket>[];

  /// Username -> the upstream that user's traffic goes through. The
  /// username carries no secret; the token half is the map's other key.
  var _routes = <String, LocalProxyRoute>{};

  String? get host => _server?.address.address;
  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// Bind on a loopback address. Not `127.0.0.1`: a random address in 127/8
  /// is not interchangeable with whatever else on the machine listens
  /// there, so a rule pointing at this relay cannot be satisfied by
  /// something else.
  Future<bool> start({InternetAddress? address}) async {
    if (_server != null) return true;
    try {
      final bind = address ?? InternetAddress.loopbackIPv4;
      final server = await ServerSocket.bind(bind, 0);
      _server = server;
      _accepting = server.listen(
        _serve,
        onError: (Object _) {},
      );
      return true;
    } on Object {
      _server = null;
      return false;
    }
  }

  Future<void> stop() async {
    await _accepting?.cancel();
    _accepting = null;
    for (final c in _clients) {
      c.destroy();
    }
    _clients.clear();
    for (final u in _upstreams) {
      u.destroy();
    }
    _upstreams.clear();
    await _server?.close();
    _server = null;
  }

  /// Replace the whole table. Routes are swapped wholesale rather than
  /// mutated so a half-applied table can never attribute one site's traffic
  /// to another's upstream.
  void setRoutes(Map<String, LocalProxyRoute> routes) {
    _routes = Map<String, LocalProxyRoute>.unmodifiable(
      Map<String, LocalProxyRoute>.of(routes),
    );
  }

  Future<void> _serve(Socket client) async {
    _clients.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    final head = _HeadBuffer();
    final incoming = client.listen(
      head.add,
      onError: (Object _) => head.close(),
      onDone: head.close,
    );
    unawaited(client.done.catchError((Object _) => client));
    Socket? upstream;
    try {
      LocalProxyRoute? route;
      ({String host, int port})? target;
      // A client that is challenged retries on the same connection, so the
      // 407 cannot close it: doing that turns "answer the challenge" into a
      // dead load, which reads as the proxy having been ignored rather than
      // refused. Bounded, so an unauthenticated client cannot sit here.
      for (var attempt = 0; attempt < 4; attempt++) {
        final requestHead = await head.readHead();
        if (requestHead == null) return;
        target = _connectTarget(requestHead);
        if (target == null) {
          client.add(_response(400, 'Bad Request'));
          await client.flush();
          client.destroy();
          return;
        }
        route = _routeFor(requestHead);
        if (route != null) break;
        // No credential, or one this relay does not know. Challenge rather
        // than relay: an unattributable tunnel has no site, so it has no
        // proxy, so letting it through would be a direct fetch.
        client.add(_challenge());
        await client.flush();
      }
      if (route == null || target == null) {
        client.destroy();
        return;
      }

      upstream = await _dial(route, target.host, target.port);
      if (upstream == null) {
        // The site named an upstream that could not be reached. Refusing is
        // the whole point: falling back to a direct dial here is the leak.
        client.add(_response(502, 'Bad Gateway'));
        await client.flush();
        client.destroy();
        return;
      }
      _upstreams.add(upstream);
      upstream.setOption(SocketOption.tcpNoDelay, true);
      unawaited(upstream.done.catchError((Object _) => upstream!));
      client.add(_response(200, 'Connection Established'));
      await _relay(client, incoming, upstream, pending: head.drain());
    } on Object {
      client.destroy();
      upstream?.destroy();
    }
  }

  Future<Socket?> _dial(LocalProxyRoute route, String host, int port) async {
    final upstream = route.upstream;
    try {
      switch (upstream.type) {
        case ProxyType.DEFAULT:
          // A site that resolves to no proxy still rides the relay, because
          // every store points here; it just goes straight out.
          return await Socket.connect(host, port,
              timeout: const Duration(seconds: 15));
        case ProxyType.SOCKS5:
        case ProxyType.TOR:
          final endpoint = _endpoint(upstream.address);
          if (endpoint == null) return null;
          return await socks5.SocksTCPClient.connect(
            [
              socks5.ProxySettings(
                await _resolve(endpoint.host),
                endpoint.port,
                username: upstream.username,
                password: route.upstreamPassword,
              ),
            ],
            // `type: unix` is how this package is told to send the hostname
            // rather than resolve it locally -- the destination name must
            // reach the SOCKS5 server, or the local resolver sees every site
            // the user meant to hide.
            InternetAddress(host, type: InternetAddressType.unix),
            port,
          ).timeout(const Duration(seconds: 20));
        case ProxyType.HTTP:
        case ProxyType.HTTPS:
          return await _dialThroughConnect(route, host, port);
      }
    } on Object {
      return null;
    }
  }

  Future<Socket?> _dialThroughConnect(
    LocalProxyRoute route,
    String host,
    int port,
  ) async {
    final endpoint = _endpoint(route.upstream.address);
    if (endpoint == null) return null;
    final socket = await Socket.connect(
      endpoint.host,
      endpoint.port,
      timeout: const Duration(seconds: 15),
    );
    final user = route.upstream.username;
    final auth = (user != null && user.isNotEmpty)
        ? 'Proxy-Authorization: Basic '
            '${base64.encode(utf8.encode('$user:${route.upstreamPassword ?? ''}'))}\r\n'
        : '';
    socket.add(utf8.encode('CONNECT $host:$port HTTP/1.1\r\n'
        'Host: $host:$port\r\n$auth\r\n'));
    await socket.flush();

    final head = _HeadBuffer();
    final sub = socket.listen(head.add,
        onError: (Object _) => head.close(), onDone: head.close);
    final reply = await head.readHead();
    await sub.cancel();
    if (reply == null || !reply.startsWith('HTTP/1.1 200')) {
      socket.destroy();
      return null;
    }
    return socket;
  }

  static Future<InternetAddress> _resolve(String host) async {
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) return parsed;
    final found = await InternetAddress.lookup(host);
    if (found.isEmpty) throw const SocketException('upstream did not resolve');
    return found.first;
  }

  static ({String host, int port})? _endpoint(String? address) {
    if (address == null || address.isEmpty) return null;
    final colon = address.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(address.substring(colon + 1));
    if (port == null) return null;
    return (host: address.substring(0, colon), port: port);
  }

  LocalProxyRoute? _routeFor(String head) {
    for (final line in head.split('\r\n')) {
      final lower = line.toLowerCase();
      if (!lower.startsWith('proxy-authorization:')) continue;
      final value = line.substring(line.indexOf(':') + 1).trim();
      if (!value.toLowerCase().startsWith('basic ')) return null;
      try {
        final decoded = utf8.decode(base64.decode(value.substring(6).trim()));
        final split = decoded.indexOf(':');
        if (split <= 0) return null;
        final user = decoded.substring(0, split);
        final token = decoded.substring(split + 1);
        final route = _routes[user];
        // Compared in full, not by prefix: the token is what stops one site
        // presenting another's username and taking its circuit.
        if (route == null || route.token != token) return null;
        return route;
      } on Object {
        return null;
      }
    }
    return null;
  }

  static ({String host, int port})? _connectTarget(String head) {
    final parts = head.split('\r\n').first.split(' ');
    if (parts.length < 2 || parts[0].toUpperCase() != 'CONNECT') return null;
    final colon = parts[1].lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(parts[1].substring(colon + 1));
    if (port == null) return null;
    return (host: parts[1].substring(0, colon), port: port);
  }

  List<int> _challenge() => utf8.encode(
        'HTTP/1.1 407 Proxy Authentication Required\r\n'
        'Proxy-Authenticate: Basic realm="$realm"\r\n'
        'Content-Length: 0\r\n\r\n',
      );

  static List<int> _response(int code, String reason) =>
      utf8.encode('HTTP/1.1 $code $reason\r\n\r\n');

  Future<void> _relay(
    Socket client,
    StreamSubscription<List<int>> incoming,
    Socket upstream, {
    List<int> pending = const [],
  }) async {
    final finished = Completer<void>();
    void finish() {
      if (!finished.isCompleted) finished.complete();
    }

    void forward(Socket to, List<int> data) {
      try {
        to.add(data);
      } on Object {
        to.destroy();
      }
    }

    if (pending.isNotEmpty) forward(upstream, pending);
    incoming
      ..onData((d) => forward(upstream, d))
      ..onError((Object _) {
        upstream.destroy();
        finish();
      })
      ..onDone(() {
        upstream.destroy();
        finish();
      });
    upstream.listen(
      (d) => forward(client, d),
      onError: (Object _) {
        client.destroy();
        finish();
      },
      onDone: () {
        client.destroy();
        finish();
      },
    );
    await finished.future;
  }
}

/// One site's entry in the relay's table.
class LocalProxyRoute {
  const LocalProxyRoute({
    required this.siteId,
    required this.token,
    required this.upstream,
    this.upstreamPassword,
  });

  final String siteId;

  /// The password half the WebView presents. Never persisted and never
  /// serialised: it is minted per run, like Android's relay token.
  final String token;

  final UserProxySettings upstream;

  /// The credential for the *upstream* proxy, if it needs one. Held here
  /// rather than on [upstream] because `UserProxySettings.toJson` must not
  /// carry a secret (PWD-005).
  final String? upstreamPassword;
}

/// Accumulates until the end of a request or response head, handing back
/// whatever arrived after it so the relay can forward it.
class _HeadBuffer {
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
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  /// Consumes one head and leaves whatever followed it in the buffer, so a
  /// client that is challenged can send its next request on the same
  /// connection.
  Future<String?> readHead() async {
    while (true) {
      final end = _end();
      if (end != null) {
        final head = String.fromCharCodes(_bytes.sublist(0, end));
        _bytes.removeRange(0, end + 4);
        return head;
      }
      if (_closed) return null;
      if (_bytes.length > 64 * 1024) return null;
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  List<int> drain() {
    final out = List<int>.of(_bytes);
    _bytes.clear();
    return out;
  }

  int? _end() {
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
