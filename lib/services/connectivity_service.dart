import 'dart:io';

import 'package:flutter/foundation.dart';

/// Simple connectivity service with a testable override.
class ConnectivityService {
  static ConnectivityService? _instance;
  static ConnectivityService get instance => _instance ??= ConnectivityService._();
  ConnectivityService._();

  /// Override for testing. When non-null, [isOnline] returns this value.
  @visibleForTesting
  static Future<bool>? onlineOverride;

  /// Reset to production behavior.
  @visibleForTesting
  static void reset() {
    _instance = null;
    onlineOverride = null;
  }

  bool? _lastKnownOnline;

  /// The most recent result of [isOnline], or null if no probe has
  /// completed yet. Synchronous so call sites that have to decide right
  /// now (e.g. webview construction picking between live URL and cached
  /// HTML) don't have to await a fresh probe — the offline-cached-HTML
  /// path needs a sync answer or chromium will start the live navigation
  /// before we can hand it `initialData`.
  ///
  /// Updated as a side effect of every [isOnline] call; seeded once at
  /// app startup via [primeLastKnownOnline].
  bool? get lastKnownOnline => _lastKnownOnline;

  /// Prime [lastKnownOnline] before any webview is created. Call this
  /// from `main()` after services are initialized but before the first
  /// `WebSpacePage` build, so the offline-cached-HTML decision has a
  /// real answer instead of `null` on cold start.
  Future<void> primeLastKnownOnline() async {
    await isOnline();
  }

  /// Returns true if the device can resolve DNS.
  Future<bool> isOnline() async {
    if (onlineOverride != null) {
      final result = await onlineOverride!;
      _lastKnownOnline = result;
      return result;
    }
    try {
      final result = await InternetAddress.lookup('example.com')
          .timeout(const Duration(seconds: 3));
      final online = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      _lastKnownOnline = online;
      return online;
    } catch (_) {
      _lastKnownOnline = false;
      return false;
    }
  }
}
