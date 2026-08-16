import 'dart:convert';
import 'dart:typed_data';

/// Per-site web microphone access mode.
///
/// There is deliberately no "hand over the real microphone" mode: this
/// feature never asks the OS for a recording permission and never opens a
/// capture device. A site either gets a synthetic microphone rendered from an
/// audio file the user picked, or nothing.
///
/// - [ask]: no decision recorded yet. The first `getUserMedia` that asks for
///   audio shows the Block / Use-audio-file popup and records the answer.
/// - [virtual]: the page gets a [MediaStream] whose audio track is the
///   user-picked file decoded once and looped forever through a WebAudio
///   graph. The real microphone is never opened and no OS microphone
///   permission is involved.
/// - [block]: audio capture requests are rejected without prompting. The page
///   sees a `NotAllowedError`, exactly as if the user had denied a real
///   browser prompt.
enum MicrophoneAccessMode { ask, virtual, block }

/// Parse a stored mode name, defaulting to [MicrophoneAccessMode.ask].
MicrophoneAccessMode microphoneAccessModeFromJson(Object? modeName) {
  if (modeName is String) {
    for (final m in MicrophoneAccessMode.values) {
      if (m.name == modeName) return m;
    }
  }
  return MicrophoneAccessMode.ask;
}

/// Source audio for [MicrophoneAccessMode.virtual]. The bytes live inline as
/// a `data:` URL so the shim can decode them with WebAudio without a file://
/// read the page's origin could not perform.
class VirtualMicrophoneSource {
  /// `data:<mime>;base64,...` payload of the picked file.
  final String dataUrl;

  /// Original file name, shown in settings so the user can tell which clip a
  /// site is set to use. Never sent to the page.
  final String fileName;

  const VirtualMicrophoneSource({
    required this.dataUrl,
    required this.fileName,
  });

  /// Decoded bytes of the `data:` payload (after `;base64,`), or null when
  /// the URL is malformed.
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
        'dataUrl': dataUrl,
        'fileName': fileName,
      };

  static VirtualMicrophoneSource? fromJson(Object? json) {
    if (json is! Map) return null;
    final dataUrl = json['dataUrl'];
    if (dataUrl is! String) return null;
    if (!dataUrl.startsWith('data:')) return null;
    return VirtualMicrophoneSource(
      dataUrl: dataUrl,
      fileName: json['fileName'] is String ? json['fileName'] as String : '',
    );
  }
}

/// A resolved microphone decision handed back to the webview after any popup
/// / file-pick has settled. [mode] is always `virtual` or `block` (never
/// `ask` — that is what triggered the resolution). [source] is set only for
/// `virtual`.
class MicrophoneDecision {
  final MicrophoneAccessMode mode;
  final VirtualMicrophoneSource? source;

  const MicrophoneDecision(this.mode, [this.source]);

  const MicrophoneDecision.block()
      : mode = MicrophoneAccessMode.block,
        source = null;

  /// The `{mode, source?}` shape the JS `webMicrophoneRequest` handler
  /// expects. `ask` degrades to `block` defensively: an unresolved decision
  /// must never read as a grant.
  Map<String, dynamic> toBridgeJson() {
    final effective =
        mode == MicrophoneAccessMode.ask ? MicrophoneAccessMode.block : mode;
    return {
      'mode': effective.name,
      if (effective == MicrophoneAccessMode.virtual && source != null)
        'source': {'dataUrl': source!.dataUrl},
    };
  }
}
