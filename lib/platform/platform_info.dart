import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

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
  static bool get useInAppWebView => isMobile;
  
  /// Returns true if webview_cef should be used (Linux/Windows/macOS desktop)
  static bool get useWebViewCef => isDesktop;
}
