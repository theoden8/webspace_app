import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/screen_share.dart';

typedef VirtualScreenPickError = VirtualMediaPickError;
typedef VirtualScreenPickResult = VirtualMediaPickResult<VirtualScreenSource>;

/// Picks the image or video served as the shared surface in
/// [ScreenShareMode.virtual].
class VirtualScreenService {
  static const int maxBytes = VirtualVisualMediaPicker.maxBytes;

  static Future<VirtualScreenPickResult> pickSource() async {
    final picked = await VirtualVisualMediaPicker.pick(maxBytes: maxBytes);
    if (picked.cancelled) return const VirtualScreenPickResult.cancelled();
    if (picked.error != null) {
      return VirtualScreenPickResult.error(picked.error!);
    }
    final source = picked.source!;
    return VirtualScreenPickResult.picked(VirtualScreenSource(
      kind: source.kind,
      dataUrl: source.dataUrl,
      fileName: source.fileName,
    ));
  }
}
