import 'dart:io' show Platform;

import 'package:flutter/services.dart';

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
  ProxyRelay._();

  /// Start or reconfigure the relay for [upstream]. Returns the loopback
  /// port to hand to `ProxyController`, or `null` if it could not bind (the
  /// caller MUST then fail closed, never clearing the override).
  Future<int?> start(UserProxySettings upstream) async {
    if (!Platform.isAndroid) return null;
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

  /// Stop the relay if running. Safe to call when not running.
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException {
      // Already stopped / channel unavailable.
    }
  }
}
