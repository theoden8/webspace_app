import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/media_metadata_strip.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/setting_labels.dart';

/// Why a picked file could not become a capture source.
enum VirtualMediaPickError { type, read, tooLarge }

extension CapturePickErrorText on CaptureText {
  String pickError(VirtualMediaPickError error) => switch (error) {
    VirtualMediaPickError.tooLarge => tooLarge,
    VirtualMediaPickError.type || VirtualMediaPickError.read => unreadable,
  };
}

/// A pick: the [source], a file the picker refused ([error]), or a dismissed
/// picker (both null).
typedef VirtualMediaPickResult<S> = ({S? source, VirtualMediaPickError? error});

typedef _Pick = VirtualMediaPickResult<PickedMedia>;

/// Picks the file a capture kind serves in place of its device.
///
/// The bytes are read eagerly, stripped of metadata and inlined as a `data:`
/// URL, because that is how every source is stored (see [VirtualSource]).
abstract final class VirtualMediaPicker {
  /// An image or video is base64'd onto the model and decoded whole by the
  /// shim, so this bounds both the persisted JSON and the page's decode
  /// footprint. 24 MiB covers a screenshot or a few seconds of phone video.
  static const int visualMaxBytes = 24 * 1024 * 1024;

  /// The shim decodes the whole clip into an `AudioBuffer` up front to loop
  /// it seamlessly, so the cap also bounds the page's decoded PCM. 8 MiB is a
  /// few minutes of compressed audio.
  static const int audioMaxBytes = 8 * 1024 * 1024;

  static const imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
  static const videoExtensions = ['mp4', 'webm', 'mov', 'm4v', 'ogv'];
  static const audioExtensions = [
    'mp3',
    'm4a',
    'aac',
    'wav',
    'ogg',
    'oga',
    'opus',
    'flac',
    'weba',
  ];

  static Future<VirtualMediaPickResult<S>> pick<S extends VirtualSource>(
    CaptureMedium<S> medium,
  ) async {
    final picked = switch (medium) {
      CaptureMedium.visual => await _visual(),
      CaptureMedium.audio => await _audio(),
    };
    final media = picked.source;
    return (
      source: media == null ? null : medium.fromPick(media),
      error: picked.error,
    );
  }

  static Future<_Pick> _visual() async {
    final file = await _read(
      [...imageExtensions, ...videoExtensions],
      visualMaxBytes,
    );
    if (file.raw case final raw?) {
      if (videoExtensions.contains(raw.extension)) {
        final bytes = stripContainerMetadata(raw.bytes, raw.extension);
        return (
          source: (
            dataUrl: _dataUrl(mimeForExtension(raw.extension, true), bytes),
            fileName: raw.fileName,
            isVideo: true,
          ),
          error: null,
        );
      }
      final jpeg = raw.extension == 'jpg' || raw.extension == 'jpeg';
      final image = await compute(stripImageMetadataForIsolate, (raw.bytes, jpeg));
      if (image == null) {
        return (source: null, error: VirtualMediaPickError.type);
      }
      return (
        source: (
          dataUrl: _dataUrl(image.mime, image.bytes),
          fileName: raw.fileName,
          isVideo: false,
        ),
        error: null,
      );
    }
    return (source: null, error: file.error);
  }

  static Future<_Pick> _audio() async {
    final file = await _read(audioExtensions, audioMaxBytes);
    if (file.raw case final raw?) {
      final bytes = stripContainerMetadata(raw.bytes, raw.extension);
      return (
        source: (
          dataUrl: _dataUrl(audioMimeForExtension(raw.extension), bytes),
          fileName: raw.fileName,
          isVideo: false,
        ),
        error: null,
      );
    }
    return (source: null, error: file.error);
  }

  static String _dataUrl(String mime, List<int> bytes) =>
      'data:$mime;base64,${base64Encode(bytes)}';

  static Future<
    ({
      ({Uint8List bytes, String extension, String fileName})? raw,
      VirtualMediaPickError? error,
    })
  >
  _read(List<String> extensions, int maxBytes) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return (raw: null, error: null);
    final file = result.files.first;
    final ext = (file.extension ?? '').toLowerCase();
    if (!extensions.contains(ext)) {
      return (raw: null, error: VirtualMediaPickError.type);
    }
    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await hostReadFileBytes(file.path!);
      } on Exception {
        return (raw: null, error: VirtualMediaPickError.read);
      }
    }
    if (bytes == null || bytes.isEmpty) {
      return (raw: null, error: VirtualMediaPickError.read);
    }
    if (bytes.length > maxBytes) {
      return (raw: null, error: VirtualMediaPickError.tooLarge);
    }
    return (
      raw: (bytes: bytes, extension: ext, fileName: file.name),
      error: null,
    );
  }

  static String mimeForExtension(String ext, bool isVideo) => switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'mp4' || 'm4v' => 'video/mp4',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'ogv' => 'video/ogg',
    _ => isVideo ? 'video/mp4' : 'image/png',
  };

  /// `decodeAudioData` sniffs the container itself, so this only has to be
  /// honest enough for the `data:` URL to be well-formed.
  static String audioMimeForExtension(String ext) => switch (ext) {
    'mp3' => 'audio/mpeg',
    'm4a' || 'aac' => 'audio/mp4',
    'wav' => 'audio/wav',
    'ogg' || 'oga' => 'audio/ogg',
    'opus' => 'audio/ogg; codecs=opus',
    'flac' => 'audio/flac',
    'weba' => 'audio/webm',
    _ => 'audio/mpeg',
  };
}
