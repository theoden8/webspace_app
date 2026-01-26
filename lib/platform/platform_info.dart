import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

/// Platform detection utilities for conditional webview loading
class PlatformInfo {
  static bool get isWeb => kIsWeb;
  static bool get isLinux => !kIsWeb && Platform.isLinux;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isMacOS => !kIsWeb && Platform.isMacOS;

  static bool get isMobile => isAndroid || isIOS;
  static bool get isDesktop => isLinux || isWindows || isMacOS;

  /// Returns true if flutter_inappwebview should be used
  static bool get useInAppWebView => !isLinux;

  /// Returns true if CEF-based webview should be used (currently disabled)
  static bool get useWebViewCef => false;

  /// Cached value for proxy support detection
  static bool? _isProxySupportedCached;

  /// Initialize platform info asynchronously. Call this at app startup.
  static Future<void> initialize() async {
    if (!useInAppWebView) {
      _isProxySupportedCached = false;
      return;
    }

    try {
      // Check if PROXY_OVERRIDE feature is supported
      // This is only supported on Android
      _isProxySupportedCached = await inapp.WebViewFeature.isFeatureSupported(
        inapp.WebViewFeature.PROXY_OVERRIDE,
      );
    } catch (e) {
      // Catch errors from platforms that don't support WebViewFeature (like macOS, iOS)
      _isProxySupportedCached = false;
    }
  }

  /// Returns true if proxy override is supported on this platform.
  /// Must call [initialize] before using this getter.
  static bool get isProxySupported {
    // Return cached value if available, otherwise false
    return _isProxySupportedCached ?? false;
  }
}
