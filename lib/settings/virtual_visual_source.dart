import 'dart:convert';
import 'dart:typed_data';

/// A user-picked still image or looped video, inlined as a `data:` URL.
///
/// Shared by every feature that substitutes a *visual* capture source (the
/// simulated camera, the simulated shared surface): all of them hand the page
/// the same two shapes and store them the same way, so the value type,
/// its JSON and its base64 decode live here once.
///
/// The bytes are inline rather than a `file://` path because the page's origin
/// cannot read a local file, and because keeping them on the model is what
/// makes them ride settings backups and land inside the encrypted archive
/// slice for archive-tier sites (same treatment as `customIconPng`).
abstract class VirtualVisualSource {
  /// `image` or `video`. Decides whether the shim draws a still frame or
  /// drives a looping `<video>` element onto the capture canvas.
  final String kind;

  /// `data:<mime>;base64,...` payload of the picked file.
  final String dataUrl;

  /// Original file name, shown in settings so the user can tell which file a
  /// site is set to use. Never sent to the page.
  final String fileName;

  const VirtualVisualSource({
    required this.kind,
    required this.dataUrl,
    required this.fileName,
  });

  bool get isVideo => kind == 'video';

  /// Decoded bytes of the `data:` payload (after `;base64,`), or null when the
  /// URL is malformed. Used by settings previews to render an image without a
  /// WebView.
  Uint8List? get bytes {
    const marker = ';base64,';
    final at = dataUrl.indexOf(marker);
    if (at < 0) return null;
    try {
      return base64Decode(dataUrl.substring(at + marker.length));
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'dataUrl': dataUrl,
        'fileName': fileName,
      };

  /// Validate a stored map and hand back its fields, or null when it is not a
  /// usable source. Subclasses call this from their own `fromJson` so every
  /// feature rejects the same malformed input.
  static ({String kind, String dataUrl, String fileName})? parse(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final dataUrl = json['dataUrl'];
    if (kind is! String || dataUrl is! String) return null;
    if (kind != 'image' && kind != 'video') return null;
    if (!dataUrl.startsWith('data:')) return null;
    return (
      kind: kind,
      dataUrl: dataUrl,
      fileName: json['fileName'] is String ? json['fileName'] as String : '',
    );
  }
}
