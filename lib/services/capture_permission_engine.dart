/// The answer to a platform's device permission request (`onPermissionRequest`),
/// the one place the app can hand a page a real camera or microphone.
library;

import 'package:webspace/settings/capture.dart';

/// Which devices a request names. iOS and macOS report a combined capture as
/// one `CAMERA_AND_MICROPHONE` resource, Android as `CAMERA` plus
/// `MICROPHONE`; both arrive here as both flags set. [other] is any resource
/// that is neither.
typedef DeviceRequest = ({bool camera, bool microphone, bool other});

/// [prompt] leaves the request to the platform: Android and Linux WPE deny
/// it, iOS 15+ and macOS 12+ show WebKit's own per-site prompt.
enum DeviceAnswer { grant, deny, prompt }

/// The host's side of one request.
typedef DeviceGrantHost = ({
  // The site's decision for the kind, asked through its grant store so the
  // on-screen gate and the archive fold apply (MIC-011, MIC-006).
  Future<bool> Function(CaptureKind kind) opensDevice,
  Future<bool> Function() cameraPermission,
  Future<bool> Function() microphonePermission,
});

abstract final class CapturePermissionEngine {
  /// A request with the microphone in it is always answered, never left to
  /// [DeviceAnswer.prompt]: WebKit's prompt would be a second decision the
  /// app cannot reconcile with the one it made (MIC-003). Every device a
  /// request names must be open for the site, because the response cannot
  /// grant part of it; the decisions are asked before the OS permissions
  /// (MIC-015, CAM-003), so a denied site never raises an OS prompt. A
  /// camera request bundled with anything but the microphone is not the
  /// camera flow's to answer (CAM-004).
  static Future<DeviceAnswer> answer(
    DeviceRequest request,
    DeviceGrantHost host,
  ) async {
    final (:camera, :microphone, :other) = request;
    if (!microphone && (!camera || other)) return DeviceAnswer.prompt;
    if (microphone && !await host.opensDevice(CaptureKind.microphone)) {
      return DeviceAnswer.deny;
    }
    if (camera && !await host.opensDevice(CaptureKind.camera)) {
      return DeviceAnswer.deny;
    }
    if (microphone && !await host.microphonePermission()) {
      return DeviceAnswer.deny;
    }
    if (camera && !await host.cameraPermission()) return DeviceAnswer.deny;
    return DeviceAnswer.grant;
  }
}
