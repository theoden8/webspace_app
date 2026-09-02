import 'package:webspace/settings/virtual_visual_source.dart';

/// Per-site screen sharing (`getDisplayMedia`) mode.
///
/// There is deliberately no "hand over the real screen" mode, and adding one
/// is not a matter of platform plumbing — it is unimplementable within this
/// app's promise. A display capture is whole-surface by construction: on
/// Android the only route is `MediaProjection`, which mirrors the entire
/// device screen, and on any platform the app's own window holds the drawer,
/// the tab strip and whichever other site the user switches to. A site granted
/// a real screen would therefore be watching every *other* site in the
/// webspace, which is the one thing per-site isolation exists to prevent. So
/// the mode a user can grant serves a file they chose, and nothing else.
///
/// - [ask]: no decision recorded yet. The first `getDisplayMedia` shows the
///   Block / Use-a-media-file popup and records the answer.
/// - [virtual]: the page gets a [MediaStream] shaped like a shared screen but
///   rendered from a user-picked image or looped video. Nothing on the device
///   is captured and no OS screen-capture permission is involved.
/// - [block]: screen sharing requests are rejected without prompting. The page
///   sees a `NotAllowedError`, exactly as if the user had dismissed a real
///   browser picker.
enum ScreenShareMode { ask, virtual, block }

/// Parse a stored mode name, defaulting to [ScreenShareMode.ask].
ScreenShareMode screenShareModeFromJson(Object? modeName) {
  if (modeName is String) {
    for (final m in ScreenShareMode.values) {
      if (m.name == modeName) return m;
    }
  }
  return ScreenShareMode.ask;
}

/// Source media for [ScreenShareMode.virtual]: the still image or looped video
/// served as the shared surface.
class VirtualScreenSource extends VirtualVisualSource {
  const VirtualScreenSource({
    required super.kind,
    required super.dataUrl,
    required super.fileName,
  });

  static VirtualScreenSource? fromJson(Object? json) {
    final parsed = VirtualVisualSource.parse(json);
    if (parsed == null) return null;
    return VirtualScreenSource(
      kind: parsed.kind,
      dataUrl: parsed.dataUrl,
      fileName: parsed.fileName,
    );
  }
}

/// A resolved screen sharing decision handed back to the webview after any
/// popup / file-pick has settled. [mode] is always `virtual` or `block` (never
/// `ask` — that is what triggered the resolution). [source] is set only for
/// `virtual`.
class ScreenShareDecision {
  final ScreenShareMode mode;
  final VirtualScreenSource? source;

  const ScreenShareDecision(this.mode, [this.source]);

  const ScreenShareDecision.block()
      : mode = ScreenShareMode.block,
        source = null;

  /// The `{mode, source?}` shape the JS `webScreenShareRequest` handler
  /// expects. `ask` degrades to `block` defensively: an unresolved decision
  /// must never read as a grant.
  Map<String, dynamic> toBridgeJson() {
    final effective = mode == ScreenShareMode.ask ? ScreenShareMode.block : mode;
    return {
      'mode': effective.name,
      if (effective == ScreenShareMode.virtual && source != null)
        'source': {'kind': source!.kind, 'dataUrl': source!.dataUrl},
    };
  }
}
