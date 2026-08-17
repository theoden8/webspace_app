import 'package:webspace/platform/host_platform.dart';
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
