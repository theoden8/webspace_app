import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/services.dart';

import 'package:webspace/services/log_service.dart';

/// Ensures the app-level camera permission needed before a webview grant.
///
/// Android is the only platform where the app must hold the CAMERA runtime
/// permission itself: `PermissionRequest.grant()` fails silently without it.
/// iOS/macOS trigger their own TCC camera prompt from WebKit when capture
/// starts (using NSCameraUsageDescription), and Linux WPE has no app-level
/// gate, so those platforms report granted here and let the OS handle it.
class CameraPermissionService {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/camera_permission');

  /// Returns true when the app may capture camera frames. On Android this
  /// shows the OS permission prompt when the permission is not yet granted.
  /// The result is deliberately not persisted anywhere: per-site intent
  /// lives on `WebViewModel.cameraMode`, while the OS-level state is
  /// re-checked on every page request so a grant made later in system
  /// settings starts working without the user touching the site setting.
  static Future<bool> ensurePermission() async {
    if (!hostIsAndroid) return true;
    try {
      final status =
          await _channel.invokeMethod<String>('ensureCameraPermission');
      if (status != 'granted') {
        LogService.instance.log(
          'Camera',
          'App camera permission not granted (status: $status); '
              'webview camera request denied.',
        );
      }
      return status == 'granted';
    } on PlatformException catch (e) {
      LogService.instance.log(
        'Camera',
        'Camera permission channel failed: ${e.code} ${e.message}',
      );
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
