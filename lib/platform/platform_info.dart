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
  
  /// Returns true if webview_cef should be used (Linux/Windows/macOS desktop)
  static bool get useWebViewCef => isLinux;

  static bool get isProxySupported {
    if (!useInAppWebView) {
      return false;
    }

    try {
      // Try to check if PROXY_OVERRIDE feature is supported
      // This will throw on platforms that don't support the feature check (like macOS)
      bool ret = false;
      inapp.WebViewFeature.isFeatureSupported(inapp.WebViewFeature.PROXY_OVERRIDE).then((val) {
        ret = val;
      }).catchError((e) {
        // Feature check not supported on this platform
        ret = false;
      });
      return ret;
    } catch (e) {
      // Catch synchronous errors from platforms that don't support WebViewFeature
      return false;
    }
  }
}
