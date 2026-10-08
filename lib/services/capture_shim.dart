import 'package:webspace/services/page_js.dart';
import 'package:webspace/settings/capture.dart';

/// The shim that serves [kind]'s requests, injected at DOCUMENT_START under
/// [CaptureKind.shimGroup] so it beats the page's own capture code.
String buildCaptureShim(CaptureKind kind) {
  final (script, label) = switch (kind) {
    CaptureKind.camera => (PageJs.cameraStream, 'Integrated Camera'),
    CaptureKind.microphone => (PageJs.microphoneStream, 'Microphone Array'),
    CaptureKind.screenShare => (PageJs.screenShare, 'Screen'),
  };
  final device = kind.publishedDevice;
  return script.withConfig({
    'shimGroup': kind.shimGroup,
    'deviceLabel': label,
    'requestHandler': kind.requestHandler,
    if (device != null) ...{
      'modeHandler': device.modeHandler,
      'deviceKind': device.deviceKind,
    },
  });
}
