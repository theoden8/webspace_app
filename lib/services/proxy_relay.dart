import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/services.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/proxy.dart';

/// Dart side of the Android local authenticating proxy relay.
///
/// Android's `ProxyController` cannot carry proxy credentials, so for a
/// credentialed upstream we start a native loopback relay
/// ([`ProxyRelayPlugin`]) and point WebView at `127.0.0.1:<port>` with no
/// credentials; the relay injects them upstream. Android-only — iOS/macOS
/// bind credentials to the per-site data store, and Linux/WebKit accepts a
/// credentialed proxy URI directly.
class ProxyRelay {
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
  /// address and port to hand to `ProxyController`, or `null` if it could not
  /// bind (the caller MUST then fail closed, never clearing the override).
  ///
  /// The host is not `127.0.0.1`: the listener binds a random address in 127/8
  /// so that finding it costs an attacker the address as well as the port.
  Future<({String host, int port})?> start(UserProxySettings upstream) async {
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
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {
        'type': type,
        'host': parts[0],
        'port': port,
        'username': upstream.username,
        'password': upstream.password,
      });
      final localHost = res?['host'] as String?;
      final localPort = res?['port'] as int?;
      if (localHost == null || localPort == null) return null;
      return (host: localHost, port: localPort);
    } on PlatformException {
      return null;
    }
  }

  /// Stop the relay if running. Safe to call when not running.
  Future<void> stop() async {
    if (!hostIsAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException {
      // Already stopped / channel unavailable.
    }
  }
}
