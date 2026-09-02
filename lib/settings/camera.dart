import 'package:webspace/settings/virtual_visual_source.dart';

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

/// Source media for [CameraAccessMode.virtual]: a still image drawn onto the
/// capture canvas, or a video looped onto it.
class VirtualCameraSource extends VirtualVisualSource {
  const VirtualCameraSource({
    required super.kind,
    required super.dataUrl,
    required super.fileName,
  });

  static VirtualCameraSource? fromJson(Object? json) {
    final parsed = VirtualVisualSource.parse(json);
    if (parsed == null) return null;
    return VirtualCameraSource(
      kind: parsed.kind,
      dataUrl: parsed.dataUrl,
      fileName: parsed.fileName,
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
