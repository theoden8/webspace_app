import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/camera.dart';

/// Per-site camera-request resolution, on top of the shared
/// [MediaGrantEngine] funnel (decide → coalesce → persist), which also
/// carries the backgrounded-site gate (CAM-011).
class CameraDecisionEngine {
  final MediaGrantEngine<CameraAccessMode, VirtualCameraSource, CameraDecision>
      _engine = MediaGrantEngine();

  /// Resolve a request for [origin].
  ///
  /// - [isSiteActive]: whether the requesting site is the one on screen. A
  ///   backgrounded site is denied outright (CAM-011): its popup would be
  ///   read as coming from the site the user is looking at, and a remembered
  ///   `real`/`virtual` grant would start capture with nothing on screen to
  ///   attribute it to. Only the grant is gated — the non-prompting mode read
  ///   behind `enumerateDevices` is not, since the shim caches it per document
  ///   and gating it would strand a site that enumerated while backgrounded.
  /// - [isTopFrame]: whether the top document is what asked. A `real` grant
  ///   is the one answer that opens the device, and the popup that produced it
  ///   named the top document — so a subframe does not inherit it and is asked
  ///   separately, under its own origin (CAM-014). The device-free answers are
  ///   inherited as they are: `block` denies, and `virtual` serves the file the
  ///   user picked, which observes nothing and is what makes a QR scanner in a
  ///   cross-origin frame work without a second popup.
  /// - [effectiveMode]: the site's current mode with archive-tier already
  ///   applied by the caller. `block` resolves immediately, `real` immediately
  ///   for the top document; `virtual` resolves immediately once
  ///   [currentSource] is non-null.
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
    required bool Function() isSiteActive,
    required bool isTopFrame,
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
        isSiteActive: isSiteActive,
        isTopFrame: isTopFrame,
        denied: () => const CameraDecision.block(),
        effectiveMode: effectiveMode,
        settled: (mode, source) {
          if (mode == CameraAccessMode.block) return CameraDecision(mode);
          if (mode == CameraAccessMode.real) {
            return isTopFrame ? CameraDecision(mode) : null;
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
