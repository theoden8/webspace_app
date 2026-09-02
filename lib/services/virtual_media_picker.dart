import 'package:webspace/platform/host_platform.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Why a picked file could not become a synthetic capture source.
enum VirtualMediaPickError { type, read, tooLarge }

/// Raw outcome of a file pick: the bytes plus the lowercased extension, or a
/// reason it was rejected. Feature services map the extension to a MIME type
/// and wrap the bytes in their own source model.
class VirtualMediaPickOutcome {
  final Uint8List? bytes;
  final String extension;
  final String fileName;
  final VirtualMediaPickError? error;

  /// True when the user dismissed the picker without choosing a file.
  final bool cancelled;

  const VirtualMediaPickOutcome.picked({
    required Uint8List this.bytes,
    required this.extension,
    required this.fileName,
  })  : error = null,
        cancelled = false;

  const VirtualMediaPickOutcome.error(VirtualMediaPickError this.error)
      : bytes = null,
        extension = '',
        fileName = '',
        cancelled = false;

  const VirtualMediaPickOutcome.cancelled()
      : bytes = null,
        extension = '',
        fileName = '',
        error = null,
        cancelled = true;
}

/// Result of a pick attempt, typed by the source model the feature builds.
/// Callers tell "user cancelled" ([cancelled]) apart from "picked but
/// rejected" ([error]) apart from success ([source]).
class VirtualMediaPickResult<S> {
  final S? source;
  final VirtualMediaPickError? error;
  final bool cancelled;

  const VirtualMediaPickResult.picked(S this.source)
      : error = null,
        cancelled = false;
  const VirtualMediaPickResult.error(VirtualMediaPickError this.error)
      : source = null,
        cancelled = false;
  const VirtualMediaPickResult.cancelled()
      : source = null,
        error = null,
        cancelled = true;
}

/// Shared file-pick + validation used by the synthetic capture sources
/// (virtual camera, virtual microphone).
///
/// The bytes are read eagerly and handed back in memory because every
/// consumer inlines them as a `data:` URL on the model: a `file://` path is
/// not readable from the page's origin, and keeping the media on the model
/// means it rides settings backups and lives inside the encrypted archive
/// slice for archive-tier sites (same treatment as `customIconPng`).
class VirtualMediaPicker {
  static Future<VirtualMediaPickOutcome> pick({
    required List<String> allowedExtensions,
    required int maxBytes,
  }) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return const VirtualMediaPickOutcome.cancelled();
    }
    final file = result.files.first;
    final ext = (file.extension ?? '').toLowerCase();
    if (!allowedExtensions.contains(ext)) {
      return const VirtualMediaPickOutcome.error(VirtualMediaPickError.type);
    }

    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await hostReadFileBytes(file.path!);
      } catch (_) {
        return const VirtualMediaPickOutcome.error(VirtualMediaPickError.read);
      }
    }
    if (bytes == null || bytes.isEmpty) {
      return const VirtualMediaPickOutcome.error(VirtualMediaPickError.read);
    }
    if (bytes.length > maxBytes) {
      return const VirtualMediaPickOutcome.error(
          VirtualMediaPickError.tooLarge);
    }
    return VirtualMediaPickOutcome.picked(
      bytes: bytes,
      extension: ext,
      fileName: file.name,
    );
  }
}

/// A picked still image or looped video, already turned into the `data:` URL
/// every visual capture source stores.
///
/// The two features that substitute a visual source (simulated camera,
/// simulated shared surface) accept exactly the same files and encode them
/// exactly the same way, so the extension list, the MIME map and the base64
/// wrapping live here rather than once per feature.
class VisualMediaPick {
  /// `image` or `video`.
  final String kind;
  final String dataUrl;
  final String fileName;

  const VisualMediaPick({
    required this.kind,
    required this.dataUrl,
    required this.fileName,
  });
}

/// Picks the image or video a site is served in place of a real visual
/// capture device.
class VirtualVisualMediaPicker {
  /// Hard cap on an inlined visual source. The bytes are base64'd onto the
  /// model in SharedPreferences and decoded whole by the shim, so this bounds
  /// both the persisted JSON and the page's decode footprint. 24 MiB of raw
  /// bytes (~32 MiB base64) covers a screenshot or a few seconds of
  /// phone-recorded video, which is all either substitution needs.
  static const int maxBytes = 24 * 1024 * 1024;

  static const imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
  static const videoExtensions = ['mp4', 'webm', 'mov', 'm4v', 'ogv'];

  static Future<VirtualMediaPickResult<VisualMediaPick>> pick({
    required int maxBytes,
  }) async {
    final outcome = await VirtualMediaPicker.pick(
      allowedExtensions: [...imageExtensions, ...videoExtensions],
      maxBytes: maxBytes,
    );
    if (outcome.cancelled) {
      return const VirtualMediaPickResult<VisualMediaPick>.cancelled();
    }
    if (outcome.error != null) {
      return VirtualMediaPickResult<VisualMediaPick>.error(outcome.error!);
    }
    final isVideo = videoExtensions.contains(outcome.extension);
    return VirtualMediaPickResult<VisualMediaPick>.picked(VisualMediaPick(
      kind: isVideo ? 'video' : 'image',
      dataUrl: 'data:${mimeForExtension(outcome.extension, isVideo)};base64,'
          '${base64Encode(outcome.bytes!)}',
      fileName: outcome.fileName,
    ));
  }

  static String mimeForExtension(String ext, bool isVideo) {
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
