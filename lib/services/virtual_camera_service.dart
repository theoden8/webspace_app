import 'dart:convert';

import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/camera.dart';

typedef VirtualCameraPickError = VirtualMediaPickError;
typedef VirtualCameraPickResult = VirtualMediaPickResult<VirtualCameraSource>;

/// Picks the image or video a site is served in [CameraAccessMode.virtual].
class VirtualCameraService {
  /// Hard cap on the inlined source. A camera substitute is a small clip or a
  /// screenshot; anything larger both bloats the persisted model JSON (base64
  /// in SharedPreferences) and risks OOM when the shim decodes it. 24 MiB of
  /// raw bytes (~32 MiB base64) covers a few seconds of phone-recorded video.
  static const int maxBytes = 24 * 1024 * 1024;

  static const _imageExts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
  static const _videoExts = ['mp4', 'webm', 'mov', 'm4v', 'ogv'];

  /// Result of a pick attempt so callers can tell "user cancelled" (null)
  /// apart from "picked but rejected" (a [VirtualCameraPickError]).
  static Future<VirtualCameraPickResult> pickSource() async {
    final outcome = await VirtualMediaPicker.pick(
      allowedExtensions: [..._imageExts, ..._videoExts],
      maxBytes: maxBytes,
    );
    if (outcome.cancelled) return const VirtualCameraPickResult.cancelled();
    if (outcome.error != null) {
      return VirtualCameraPickResult.error(outcome.error!);
    }

    final isVideo = _videoExts.contains(outcome.extension);
    final mime = _mimeFor(outcome.extension, isVideo);
    final dataUrl = 'data:$mime;base64,${base64Encode(outcome.bytes!)}';
    return VirtualCameraPickResult.picked(VirtualCameraSource(
      kind: isVideo ? 'video' : 'image',
      dataUrl: dataUrl,
      fileName: outcome.fileName,
    ));
  }

  static String _mimeFor(String ext, bool isVideo) {
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mov':
        return 'video/quicktime';
      case 'ogv':
        return 'video/ogg';
      default:
        return isVideo ? 'video/mp4' : 'image/png';
    }
  }
}
