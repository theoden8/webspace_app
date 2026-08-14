import 'dart:convert';
import 'dart:typed_data';

/// Per-site web camera access mode.
///
/// - [ask]: no decision recorded yet. The first camera-only `getUserMedia`
///   shows the Allow/Use file/Block popup and records the answer.
/// - [real]: the device camera is handed to the page. Grants the native
///   webview permission request (and, on Android, ensures the app-level
///   CAMERA runtime permission first).
/// - [virtual]: the page gets a synthetic [MediaStream] rendered from a
///   user-picked image or looped video instead of the device camera. The
///   real camera is never opened and no OS camera permission is involved:
///   the JS shim resolves `getUserMedia` from a canvas `captureStream()`.
///   Intended for QR-scan flows where the code is already on the device
///   (a screenshot, a saved photo) or where the user does not want to
///   expose their surroundings.
/// - [block]: camera requests are rejected without prompting. The page
///   sees a `NotAllowedError`, exactly as if the user had denied a real
///   browser prompt.
enum CameraAccessMode { ask, real, virtual, block }

/// Parse a stored mode name, tolerating the legacy `bool? cameraAllowed`
/// representation this field replaced (`true` -> [CameraAccessMode.real],
/// `false` -> [CameraAccessMode.block], absent -> [CameraAccessMode.ask]).
CameraAccessMode cameraAccessModeFromJson(Object? modeName, Object? legacyBool) {
  if (modeName is String) {
    for (final m in CameraAccessMode.values) {
      if (m.name == modeName) return m;
    }
  }
  if (legacyBool is bool) {
    return legacyBool ? CameraAccessMode.real : CameraAccessMode.block;
  }
  return CameraAccessMode.ask;
}

/// Source media for [CameraAccessMode.virtual]. The bytes live inline as a
/// `data:` URL so the shim can hand them straight to an `<img>`/`<video>`
/// element without a file:// read the page's origin could not perform.
class VirtualCameraSource {
  /// `image` or `video`. Decides whether the shim draws a still frame or
  /// drives a looping `<video>` element onto the capture canvas.
  final String kind;

  /// `data:<mime>;base64,...` payload of the picked file.
  final String dataUrl;

  /// Original file name, shown in settings so the user can tell which
  /// clip a site is set to use. Never sent to the page.
  final String fileName;

  const VirtualCameraSource({
    required this.kind,
    required this.dataUrl,
    required this.fileName,
  });

  bool get isVideo => kind == 'video';

  /// Decoded bytes of the `data:` payload (after `;base64,`), or null when
  /// the URL is malformed. Used by the settings preview to render an image
  /// without a WebView.
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

  static VirtualCameraSource? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final dataUrl = json['dataUrl'];
    if (kind is! String || dataUrl is! String) return null;
    if (kind != 'image' && kind != 'video') return null;
    if (!dataUrl.startsWith('data:')) return null;
    return VirtualCameraSource(
      kind: kind,
      dataUrl: dataUrl,
      fileName: json['fileName'] is String ? json['fileName'] as String : '',
    );
  }
}

/// A resolved camera decision handed back to the webview after any popup /
/// file-pick has settled. [mode] is always one of `real` / `virtual` /
/// `block` (never `ask` — that is what triggered the resolution). [source]
/// is set only for `virtual`.
class CameraDecision {
  final CameraAccessMode mode;
  final VirtualCameraSource? source;

  const CameraDecision(this.mode, [this.source]);

  const CameraDecision.block()
      : mode = CameraAccessMode.block,
        source = null;

  /// The `{mode, source?}` shape the JS `webCameraRequest` handler expects.
  /// `ask` degrades to `block` defensively: the shim must never be told to
  /// fall through to the real camera on an unresolved decision.
  Map<String, dynamic> toBridgeJson() {
    final effective = mode == CameraAccessMode.ask ? CameraAccessMode.block : mode;
    return {
      'mode': effective.name,
      if (effective == CameraAccessMode.virtual && source != null)
        'source': {'kind': source!.kind, 'dataUrl': source!.dataUrl},
    };
  }
}
