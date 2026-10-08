import 'package:webspace/services/camera_stream_shim.dart';
import 'package:webspace/services/microphone_stream_shim.dart';
import 'package:webspace/services/screen_share_shim.dart';
import 'package:webspace/settings/capture.dart';

/// The shim that serves [kind]'s requests, injected at DOCUMENT_START under
/// [CaptureKind.shimGroup] so it beats the page's own capture code.
String buildCaptureShim(CaptureKind kind) => switch (kind) {
  CaptureKind.camera => buildCameraStreamShim(),
  CaptureKind.microphone => buildMicrophoneStreamShim(),
  CaptureKind.screenShare => buildScreenShareShim(),
};
