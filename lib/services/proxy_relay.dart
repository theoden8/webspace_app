import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/services.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/proxy.dart';

/// The relay operations the router service depends on.
///
/// Narrow on purpose: it exists so `ProxyRouterService` can be driven by
/// a fake in tests without a platform channel, per the engine/service
/// split in CLAUDE.md.
abstract interface class ProxyRelayApi {
  Future<int?> startRouter(String realm);
  Future<bool> setRoutes(Map<String, Map<String, Object?>> routes);

  /// Probe pairs the relay has observed: nonce -> the siteId whose
  /// credential carried it. The attribution self-test reads this.
  Future<Map<String, String>> probeResults();
  Future<void> clearProbeResults();

  Future<void> stop();
}

/// Dart side of the Android local authenticating proxy relay.
///
/// Android's `ProxyController` cannot carry proxy credentials, so for a
/// credentialed upstream we start a native loopback relay
/// ([`ProxyRelayPlugin`]) and point WebView at `127.0.0.1:<port>` with no
/// credentials; the relay injects them upstream. Android-only — iOS/macOS
/// bind credentials to the per-site data store, and Linux/WebKit accepts a
/// credentialed proxy URI directly.
class ProxyRelay implements ProxyRelayApi {
  static const MethodChannel _channel =
      MethodChannel('org.codeberg.theoden8.webspace/proxy_relay');

  static final ProxyRelay instance = ProxyRelay._();
  ProxyRelay._() {
    // The native side posts every relay event (accept, upstream connect
    // attempt/result, 502, start/stop) over this channel so they land in
    // the in-app Logs tab alongside the `Proxy` events.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'logEvent') {
        final msg = (call.arguments as Map?)?['msg']?.toString();
        if (msg != null) {
          LogService.instance.log(
            'ProxyRelay',
            msg,
            sensitivity: LogSensitivity.sensitive,
          );
        }
      }
      return null;
    });
  }

  /// Start or reconfigure the relay for [upstream]. Returns the loopback
  /// port to hand to `ProxyController`, or `null` if it could not bind (the
  /// caller MUST then fail closed, never clearing the override).
  Future<int?> start(UserProxySettings upstream) async {
    if (!hostIsAndroid) return null;
    final address = upstream.address;
    if (address == null) return null;
    final parts = address.split(':');
    if (parts.length != 2) return null;
    final port = int.tryParse(parts[1]);
    if (port == null) return null;
    final type = switch (upstream.type) {
      ProxyType.HTTPS => 'https',
      ProxyType.SOCKS5 => 'socks5',
      _ => 'http',
    };
    try {
      return await _channel.invokeMethod<int>('start', {
        'type': type,
        'host': parts[0],
        'port': port,
        'username': upstream.username,
        'password': upstream.password,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Start (or reconfigure) the relay in router mode, fronting every
  /// site's upstream at once. Returns the loopback port to hand to
  /// `ProxyController`, or `null` if it could not bind (the caller MUST
  /// then fail closed, never clearing the override).
  ///
  /// [realm] is the nonce the relay names in its `407`; the Dart side
  /// answers a challenge only when it matches (see
  /// `ProxyRouterEngine.shouldAnswerChallenge`).
  @override
  Future<int?> startRouter(String realm) async {
    if (!hostIsAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('startRouter', {'realm': realm});
    } on PlatformException {
      return null;
    }
  }

  /// Replace the relay's route table. Keys are per-site credentials from
  /// `ProxyRouterEngine.credentialFor`; a site absent from the table
  /// cannot reach the network, which is the fail-closed direction.
  ///
  /// Returns false if the table was rejected, in which case the caller
  /// MUST NOT treat router mode as active.
  @override
  Future<bool> setRoutes(Map<String, Map<String, Object?>> routes) async {
    if (!hostIsAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setRoutes', {
        'routes': routes,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<Map<String, String>> probeResults() async {
    if (!hostIsAndroid) return const {};
    try {
      final raw = await _channel.invokeMapMethod<String, String>('probeResults');
      return raw ?? const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<void> clearProbeResults() async {
    if (!hostIsAndroid) return;
    try {
      await _channel.invokeMethod('clearProbeResults');
    } on PlatformException {
      // Channel unavailable; the next activation re-reads anyway.
    }
  }

  /// Stop the relay if running. Safe to call when not running.
  @override
  Future<void> stop() async {
    if (!hostIsAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException {
      // Already stopped / channel unavailable.
    }
  }
}
