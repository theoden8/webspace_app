import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:webspace/settings/camera.dart';

/// Picks the image or video a site is served in [CameraAccessMode.virtual].
///
/// The bytes are inlined into the model as a `data:` URL so the shim can hand
/// them straight to an `<img>`/`<video>` — a file:// path would not be
/// readable from the page's origin, and keeping the media on the model means
/// it rides settings backups and lives inside the encrypted archive slice for
/// archive-tier sites (same treatment as `customIconPng`).
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
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [..._imageExts, ..._videoExts],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return const VirtualCameraPickResult.cancelled();
    }
    final file = result.files.first;
    final ext = (file.extension ?? '').toLowerCase();
    final isVideo = _videoExts.contains(ext);
    final isImage = _imageExts.contains(ext);
    if (!isVideo && !isImage) {
      return const VirtualCameraPickResult.error(VirtualCameraPickError.type);
    }

    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (_) {
        return const VirtualCameraPickResult.error(VirtualCameraPickError.read);
      }
    }
    if (bytes == null || bytes.isEmpty) {
      return const VirtualCameraPickResult.error(VirtualCameraPickError.read);
    }
    if (bytes.length > maxBytes) {
      return const VirtualCameraPickResult.error(VirtualCameraPickError.tooLarge);
    }

    final mime = _mimeFor(ext, isVideo);
    final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
    return VirtualCameraPickResult.picked(VirtualCameraSource(
      kind: isVideo ? 'video' : 'image',
      dataUrl: dataUrl,
      fileName: file.name,
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

enum VirtualCameraPickError { type, read, tooLarge }

class VirtualCameraPickResult {
  final VirtualCameraSource? source;
  final VirtualCameraPickError? error;

  /// True when the user dismissed the picker without choosing a file.
  final bool cancelled;

  const VirtualCameraPickResult.picked(VirtualCameraSource this.source)
      : error = null,
        cancelled = false;
  const VirtualCameraPickResult.error(VirtualCameraPickError this.error)
      : source = null,
        cancelled = false;
  const VirtualCameraPickResult.cancelled()
      : source = null,
        error = null,
        cancelled = true;
}
