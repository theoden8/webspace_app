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

  /// Returns true if the device can resolve DNS.
  Future<bool> isOnline() async {
    if (onlineOverride != null) return onlineOverride!;
    try {
      final result = await InternetAddress.lookup('example.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
