import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/https_upgrade_engine.dart';

/// The engine driven over real sockets, in the order the webview call site
/// uses it: ask `upgradeFor`, attempt the load, hand a failure to
/// `fallbackFor`, load what that returns.
///
/// What this adds over `https_upgrade_engine_test.dart`, which feeds the
/// engine hand-written URLs: the failure is a real refused connection rather
/// than a test calling `fallbackFor` directly, and the sequencing across three
/// navigations is exercised rather than asserted a step at a time.
///
/// **What it does not cover, and cannot.** The app's loads run on chromium's
/// network stack inside a webview, not on `HttpClient`, so this is the engine
/// composing with *a* client, not with the one that ships. TLS outcomes are
/// deliberately absent for the same reason: whether a rejected certificate or
/// a stalled handshake reaches `onReceivedError` at all, and how fast, is
/// chromium's behaviour and a Dart client answers a different question. Those
/// need the integration tier and a device. The `shouldOverrideUrlLoading` and
/// `onReceivedError` wiring is gated structurally in
/// `test/js/page_bridge_authority.test.js`.
///
/// Hermetic: no `/etc/hosts`, no DNS, no external network.
/// `HttpClient.connectionFactory` sends the socket to loopback while the URL
/// keeps a dotted hostname, which HTTPS-003 requires (it refuses IP literals
/// and single-label names, so `127.0.0.1` would never be upgraded at all).
void main() {
  /// A client whose DNS is a lookup table. A scheme with no entry has nothing
  /// listening, which is the shape of a host that simply has no TLS.
  HttpClient clientFor(Map<String, int> httpPorts, Map<String, int> httpsPorts) {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 2)
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        final table = uri.scheme == 'https' ? httpsPorts : httpPorts;
        final port = table[uri.host];
        if (port == null) {
          throw const SocketException('connection refused');
        }
        return Socket.startConnect(InternetAddress.loopbackIPv4, port);
      };
  }

  Future<({String loaded, bool fellBack})> navigate(
    HttpsUpgradeEngine engine,
    HttpClient client,
    String url,
  ) async {
    final upgraded = engine.upgradeFor(url, enabled: true);
    final target = upgraded ?? url;
    try {
      final res = await (await client.getUrl(Uri.parse(target))).close();
      await res.drain<void>();
      engine.recordUpgradeSuccess(target);
      return (loaded: target, fellBack: false);
    } catch (_) {
      final fallback = engine.fallbackFor(target);
      if (fallback == null) rethrow;
      final res = await (await client.getUrl(Uri.parse(fallback))).close();
      await res.drain<void>();
      return (loaded: fallback, fellBack: true);
    }
  }

  Future<HttpServer> plainServer() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((r) => r.response
      ..write('plain')
      ..close());
    return s;
  }

  test('a refused TLS port falls back, and the host is not probed again',
      () async {
    final origin = await plainServer();
    final engine = HttpsUpgradeEngine();
    final client = clientFor({'httponly.test': origin.port}, {});
    try {
      final first = await navigate(
          engine, client, 'http://httponly.test/login.php?a=1');
      expect(first.loaded, 'http://httponly.test/login.php?a=1',
          reason: 'the fallback must be the original URL, query intact');
      expect(first.fellBack, isTrue);
      expect(engine.isKnownHttpOnly('httponly.test'), isTrue);

      // The second navigation costs no failed connection: the engine does not
      // upgrade, so nothing is attempted over TLS at all (HTTPS-002).
      final second = await navigate(engine, client, 'http://httponly.test/b');
      expect(second.loaded, 'http://httponly.test/b');
      expect(second.fellBack, isFalse);

      // And a third, to show the record is the host and not the URL.
      final third = await navigate(engine, client, 'http://httponly.test/c?x=1');
      expect(third.loaded, 'http://httponly.test/c?x=1');
      expect(third.fellBack, isFalse);
    } finally {
      client.close(force: true);
      await origin.close(force: true);
    }
  });

  test('one http-only host does not stop another host being upgraded',
      () async {
    final origin = await plainServer();
    final engine = HttpsUpgradeEngine();
    final client = clientFor(
        {'httponly.test': origin.port, 'other.test': origin.port}, {});
    try {
      await navigate(engine, client, 'http://httponly.test/a');
      expect(engine.isKnownHttpOnly('httponly.test'), isTrue);
      expect(engine.isKnownHttpOnly('other.test'), isFalse);

      // `other.test` is still tried over https, and falls back on its own.
      final r = await navigate(engine, client, 'http://other.test/a');
      expect(r.fellBack, isTrue);
      expect(engine.isKnownHttpOnly('other.test'), isTrue);
    } finally {
      client.close(force: true);
      await origin.close(force: true);
    }
  });

  test('a host the engine refuses to upgrade is loaded as-is, never marked',
      () async {
    final origin = await plainServer();
    final engine = HttpsUpgradeEngine();
    // HTTPS-003: a non-default port is an ad-hoc service. It must reach the
    // network exactly as the site asked, with no failed TLS attempt first.
    final client = clientFor({'app.test': origin.port}, {});
    try {
      final r = await navigate(engine, client, 'http://app.test:8080/health');
      expect(r.loaded, 'http://app.test:8080/health');
      expect(r.fellBack, isFalse);
      expect(engine.isKnownHttpOnly('app.test'), isFalse);
    } finally {
      client.close(force: true);
      await origin.close(force: true);
    }
  });
}
