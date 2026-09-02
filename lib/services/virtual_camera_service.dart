import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/camera.dart';

typedef VirtualCameraPickError = VirtualMediaPickError;
typedef VirtualCameraPickResult = VirtualMediaPickResult<VirtualCameraSource>;

/// Picks the image or video a site is served in [CameraAccessMode.virtual].
class VirtualCameraService {
  static const int maxBytes = VirtualVisualMediaPicker.maxBytes;

  /// Result of a pick attempt so callers can tell "user cancelled" (null)
  /// apart from "picked but rejected" (a [VirtualCameraPickError]).
  static Future<VirtualCameraPickResult> pickSource() async {
    final picked = await VirtualVisualMediaPicker.pick(maxBytes: maxBytes);
    if (picked.cancelled) return const VirtualCameraPickResult.cancelled();
    if (picked.error != null) {
      return VirtualCameraPickResult.error(picked.error!);
    }
    final source = picked.source!;
    return VirtualCameraPickResult.picked(VirtualCameraSource(
      kind: source.kind,
      dataUrl: source.dataUrl,
      fileName: source.fileName,
    ));
  }
}
