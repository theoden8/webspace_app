import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/camera.dart';

/// Per-site camera-request resolution, on top of the shared
/// [MediaGrantEngine] funnel (decide → coalesce → persist).
class CameraDecisionEngine {
  final MediaGrantEngine<CameraAccessMode, VirtualCameraSource, CameraDecision>
      _engine = MediaGrantEngine();

  /// Resolve a request for [origin].
  ///
  /// - [effectiveMode]: the site's current mode with archive-tier already
  ///   applied by the caller. `real`/`block` resolve immediately; `virtual`
  ///   resolves immediately once [currentSource] is non-null.
  /// - [currentSource]: reads the site's picked virtual source (may change
  ///   after [persist]).
  /// - [resolve]: host UI — shows the Block/Use-file/Allow popup or the file
  ///   picker and returns the user's choice. Only invoked for an unresolved
  ///   `ask`, or a `virtual` site with no source yet.
  /// - [persist]: applies the resolved mode (always) and source (only when
  ///   non-null, so a cancelled pick leaves the prior source intact) to the
  ///   host's storage.
  /// - [save]: flushes the host's storage (no-op for nested screens).
  Future<CameraDecision> decide({
    required String origin,
    required CameraAccessMode effectiveMode,
    required VirtualCameraSource? Function() currentSource,
    required Future<CameraDecision> Function(
            String origin, CameraAccessMode current)
        resolve,
    required void Function(CameraAccessMode mode, VirtualCameraSource? source)
        persist,
    required Future<void> Function() save,
  }) =>
      _engine.decide(
        origin: origin,
        effectiveMode: effectiveMode,
        settled: (mode, source) {
          if (mode == CameraAccessMode.real ||
              mode == CameraAccessMode.block) {
            return CameraDecision(mode);
          }
          if (mode == CameraAccessMode.virtual && source != null) {
            return CameraDecision(mode, source);
          }
          return null;
        },
        currentSource: currentSource,
        resolve: resolve,
        persist: (d) => persist(d.mode, d.source),
        finalize: (d, fallback) => CameraDecision(d.mode, d.source ?? fallback),
        save: save,
      );
}
