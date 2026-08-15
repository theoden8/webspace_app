import 'package:webspace/settings/camera.dart';

/// Pure orchestration for resolving a per-site camera request.
///
/// Both the parent webview (`WebViewModel.getWebView`) and the transient
/// nested screen (`InAppWebViewScreen`) route camera requests through one
/// instance of this so the decide → coalesce → persist flow lives in exactly
/// one place (the parent persists onto the model; the nested screen keeps its
/// answer in memory — only the collaborators differ). No Flutter imports, no
/// `setState`, no `BuildContext`: the host passes the model/state accessors as
/// closures, matching the engine convention in `cookie_isolation.dart`.
class CameraDecisionEngine {
  /// Coalesces a burst of requests (scanner libraries retry `getUserMedia`)
  /// onto a single popup / file-pick. Cleared once the decision settles.
  Future<CameraDecision>? _inFlight;

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
    required Future<CameraDecision> Function(String origin, CameraAccessMode current)
        resolve,
    required void Function(CameraAccessMode mode, VirtualCameraSource? source)
        persist,
    required Future<void> Function() save,
  }) async {
    if (effectiveMode == CameraAccessMode.real ||
        effectiveMode == CameraAccessMode.block) {
      return CameraDecision(effectiveMode);
    }
    if (effectiveMode == CameraAccessMode.virtual && currentSource() != null) {
      return CameraDecision(effectiveMode, currentSource());
    }
    _inFlight ??= () async {
      final decision = await resolve(origin, effectiveMode);
      persist(decision.mode, decision.source);
      await save();
      return CameraDecision(decision.mode, decision.source ?? currentSource());
    }();
    try {
      return await _inFlight!;
    } finally {
      _inFlight = null;
    }
  }
}
