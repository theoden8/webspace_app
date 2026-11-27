import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

/// The WPE WebKit this Linux build runs, read once at startup and asked of
/// as each webview is built: whether it reports page icons (ICON-009) and
/// which way it reads `disableAnimations` (A11Y-011).
class WpeVersion {
  static String? _reported;

  /// What WPE said its version is; null off Linux or when it said nothing.
  static String? get reported => _reported;

  static Future<void> probe() async {
    if (!hostIsLinux) return;
    try {
      _reported = await inapp.WebViewEnvironment.getAvailableVersion();
    } on PlatformException catch (e) {
      LogTag.webView.warning('WPE version unknown: $e');
    } on MissingPluginException catch (e) {
      LogTag.webView.warning('WPE version unknown: $e');
    }
  }
}

/// [version]'s major, minor and patch, null for any part it does not name
/// as a number.
({int? major, int? minor, int? patch}) wpeRelease(String? version) {
  final parts = (version ?? '').split('.').map(int.tryParse).toList();
  int? at(int i) => i < parts.length ? parts[i] : null;
  return (major: at(0), minor: at(1), patch: at(2));
}

/// Whether WPE [version] applies `WPE_SETTING_DISABLE_ANIMATIONS` the wrong
/// way round: 2.54.0 and 2.54.1, fixed in 2.54.2 (WebKit bug 325212).
bool wpeInvertsDisableAnimations(String? version) =>
    switch (wpeRelease(version)) {
      (major: 2, minor: 54, patch: 0 || 1) => true,
      _ => false,
    };

/// The `disableAnimations` a Linux webview is given so its pages see
/// `prefers-reduced-motion` as [reduced] says, on WPE [version].
bool wpeDisableAnimations({required bool reduced, required String? version}) =>
    reduced != wpeInvertsDisableAnimations(version);
