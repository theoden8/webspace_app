import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/services.dart';

import 'package:webspace/services/log_service.dart';

/// Ensures an app-level capture permission needed before a webview grant.
///
/// Android is the only platform where the app must hold the runtime
/// permission itself: `PermissionRequest.grant()` fails silently without it.
/// iOS/macOS trigger their own TCC prompt from WebKit when capture starts
/// (using the matching usage description), and Linux WPE has no app-level
/// gate, so those platforms report granted here and let the OS handle it.
///
/// The result is deliberately not persisted anywhere: per-site intent lives
/// on the model (`WebViewModel.captures`), while the OS-level state is
/// re-checked on every page request, so a permission revoked in system
/// settings stops the next request and one granted later starts working,
/// without the user touching the site setting (CAM/MIC-015).
class CapturePermissionService {
  const CapturePermissionService._(
    this._channelName, {
    required String method,
    required LogTag tag,
  })  : _method = method,
        _tag = tag;

  final String _channelName;
  final String _method;
  final LogTag _tag;

  static const camera = CapturePermissionService._(
    'org.codeberg.theoden8.webspace/camera_permission',
    method: 'ensureCameraPermission',
    tag: LogTag.camera,
  );

  static const microphone = CapturePermissionService._(
    'org.codeberg.theoden8.webspace/microphone_permission',
    method: 'ensureMicrophonePermission',
    tag: LogTag.microphone,
  );

  /// Returns true when the app may capture. On Android this shows the OS
  /// permission prompt when the permission is not yet granted.
  Future<bool> ensure() async {
    if (!hostIsAndroid) return true;
    try {
      final status =
          await MethodChannel(_channelName).invokeMethod<String>(_method);
      if (status != 'granted') {
        _tag.debug(
            'App ${_tag.label.toLowerCase()} permission not granted (status: '
            '$status); webview request denied.');
      }
      return status == 'granted';
    } on PlatformException catch (e) {
      _tag.debug(
          '${_tag.label} permission channel failed: ${e.code} ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// Camera half of [CapturePermissionService], kept as a named entry point
/// because the camera grant path and its tests reach for it by name.
class CameraPermissionService {
  static Future<bool> ensurePermission() =>
      CapturePermissionService.camera.ensure();
}

/// Microphone half. Holding `RECORD_AUDIO` is what MIC-015 accepts in
/// exchange for the containment contract; this is the only place the app asks
/// for it, and only while resolving a grant the user already allowed.
class MicrophonePermissionService {
  static Future<bool> ensurePermission() =>
      CapturePermissionService.microphone.ensure();
}
