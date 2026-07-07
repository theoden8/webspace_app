import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/services/log_service.dart';

/// Detects iOS Lockdown Mode, which strips web APIs (FileReader, IndexedDB,
/// WebGL, Web Audio, WASM, JIT) from every third-party app's webviews.
/// Complex sites degrade badly under it — LinkedIn drops the session when
/// its storage layer fails — and the app cannot opt out: disabling
/// `WKWebpagePreferences.isLockdownModeEnabled` requires the
/// `com.apple.developer.web-browser` entitlement. All the app can do is
/// detect the restriction and tell the user how to exclude WebSpace
/// (Settings > Privacy & Security > Lockdown Mode > Configure Web Browsing).
class LockdownModeService {
  LockdownModeService._();
  static final LockdownModeService instance = LockdownModeService._();

  static const MethodChannel _channel =
      MethodChannel('org.codeberg.theoden8.webspace/lockdown_mode');

  /// Test seam: overrides the platform gate so the channel path is
  /// exercisable off-device.
  @visibleForTesting
  bool? debugIsIOS;

  Future<bool> isLockdownModeEnabled() async {
    final isIOS = debugIsIOS ?? Platform.isIOS;
    if (!isIOS) return false;
    try {
      final enabled = await _channel.invokeMethod<bool>('isLockdownModeEnabled');
      if (enabled == true) {
        LogService.instance.log(
          'LockdownMode',
          'iOS Lockdown Mode is enabled: webviews run without '
              'FileReader/IndexedDB/WebGL/Web Audio/WASM/JIT',
          level: LogLevel.warning,
        );
      }
      return enabled ?? false;
    } catch (e) {
      LogService.instance.log('LockdownMode', 'probe failed (non-fatal): $e');
      return false;
    }
  }
}
