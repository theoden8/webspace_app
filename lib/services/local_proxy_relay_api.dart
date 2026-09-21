import 'dart:convert';

import 'package:webspace/services/local_proxy_relay.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/settings/proxy.dart';

/// [ProxyRelayApi] over the in-process [LocalProxyRelay], so the router
/// (PROXY-013) can run where there is no Kotlin relay plugin.
///
/// Android's relay is native because `ProxyController` carries one rule for
/// the process and Chromium answers the `407` through
/// `onReceivedHttpAuthRequest`. Apple needs neither: each container store
/// gets its own `proxyConfigurations` naming this endpoint, and the
/// credential rides `ProxyConfiguration.applyCredential` preemptively, so a
/// Dart `ServerSocket` is the whole relay.
///
/// The route table arrives in the platform-channel wire shape because
/// `ProxyRouterService` builds one table for both relays. Decoding it back
/// here keeps that single source of truth, at the cost of one encode/decode
/// round trip per route change.
class LocalProxyRelayApi implements ProxyRelayApi {
  LocalProxyRelayApi();

  LocalProxyRelay? _relay;

  @override
  String? lastError;

  /// The running relay, for callers that need its endpoint.
  LocalProxyRelay? get relay => _relay;

  @override
  Future<({String host, int port})?> startRouter(String realm) async {
    final existing = _relay;
    if (existing != null && existing.isRunning) {
      if (existing.realm == realm) {
        final host = existing.host;
        final port = existing.port;
        if (host != null && port != null) return (host: host, port: port);
      }
      // A different realm is a different run of the router; the old socket
      // must not keep answering with the old challenge.
      await existing.stop();
    }
    final relay = LocalProxyRelay(realm: realm);
    if (!await relay.start()) {
      lastError = relay.lastError ?? 'the relay socket did not bind';
      _relay = null;
      return null;
    }
    _relay = relay;
    lastError = null;
    final host = relay.host;
    final port = relay.port;
    if (host == null || port == null) {
      lastError = 'the relay bound without an address';
      await relay.stop();
      _relay = null;
      return null;
    }
    return (host: host, port: port);
  }

  @override
  Future<bool> setRoutes(Map<String, Map<String, Object?>> routes) async {
    final relay = _relay;
    if (relay == null || !relay.isRunning) {
      lastError = 'no relay is running';
      return false;
    }
    final decoded = <String, LocalProxyRoute>{};
    for (final entry in routes.entries) {
      final route = decodeRoute(entry.key, entry.value);
      if (route == null) {
        // Fail the whole table rather than install part of it: a half
        // table sends the missing site's traffic to a 502, which reads as
        // a broken proxy rather than as the misconfiguration it is.
        lastError = 'a route could not be decoded';
        return false;
      }
      decoded[route.username] = route.route;
    }
    relay.setRoutes(decoded);
    lastError = null;
    return true;
  }

  @override
  Future<Map<String, String>> probeResults() async =>
      _relay?.probeResults ?? const {};

  @override
  Future<void> clearProbeResults() async => _relay?.clearProbeResults();

  @override
  Future<void> stop() async {
    await _relay?.stop();
    _relay = null;
  }

  /// Turn one wire entry back into the relay's own route type.
  ///
  /// The key is the `Proxy-Authorization: Basic` payload
  /// (`base64(<username>:<token>)`); the relay matches on the username and
  /// compares the token in full, so both halves have to come back out.
  static ({String username, LocalProxyRoute route})? decodeRoute(
    String credential,
    Map<String, Object?> wire,
  ) {
    final String decoded;
    try {
      decoded = utf8.decode(base64.decode(credential));
    } on Object {
      return null;
    }
    final split = decoded.indexOf(':');
    if (split <= 0) return null;
    final username = decoded.substring(0, split);
    final token = decoded.substring(split + 1);
    if (token.isEmpty) return null;

    final siteId = wire['siteId'];
    if (siteId is! String) return null;
    final type = switch (wire['type']) {
      'direct' => ProxyType.DEFAULT,
      'socks5' => ProxyType.SOCKS5,
      'https' => ProxyType.HTTPS,
      'http' => ProxyType.HTTP,
      _ => null,
    };
    if (type == null) return null;
    String? address;
    if (type != ProxyType.DEFAULT) {
      final host = wire['host'];
      final port = wire['port'];
      if (host is! String || host.isEmpty || port is! int || port <= 0) {
        return null;
      }
      address = '$host:$port';
    }
    final upstreamUser = wire['username'];
    final upstreamPassword = wire['password'];
    return (
      username: username,
      route: LocalProxyRoute(
        siteId: siteId,
        token: token,
        upstream: UserProxySettings(
          type: type,
          address: address,
          username: upstreamUser is String ? upstreamUser : null,
        ),
        upstreamPassword:
            upstreamPassword is String ? upstreamPassword : null,
      ),
    );
  }
}
