/// Pure orchestration shared by the per-site capture grants (camera,
/// microphone): decide → coalesce → persist.
///
/// Both the parent webview (`WebViewModel.getWebView`) and the transient
/// nested screen (`InAppWebViewScreen`) route capture requests through one
/// instance per feature, so the flow lives in exactly one place — only the
/// collaborators differ (the parent persists onto the model and saves; the
/// nested screen keeps its answer in memory). No Flutter imports, no
/// `setState`, no `BuildContext`: the host passes the model/state accessors
/// as closures, matching the engine convention in `cookie_isolation.dart`.
///
/// [M] is the feature's mode enum, [S] its picked source, [D] its decision.
class MediaGrantEngine<M, S, D> {
  /// Coalesces a burst of requests (capture libraries retry `getUserMedia`)
  /// onto a single popup / file-pick. Cleared once the decision settles.
  Future<D>? _inFlight;

  /// Resolve a request for [origin].
  ///
  /// - [effectiveMode]: the site's current mode with archive-tier already
  ///   applied by the caller.
  /// - [settled]: maps a (mode, source) pair to the decision that needs no
  ///   UI, or null when the host must be asked.
  /// - [currentSource]: reads the site's picked source (may change after
  ///   [persist]).
  /// - [resolve]: host UI — shows the popup or the file picker and returns
  ///   the user's choice. Only invoked when [settled] returned null.
  /// - [persist]: applies the resolved decision to the host's storage.
  /// - [finalize]: builds the decision handed back to the page, given the
  ///   resolved one and the source already on file (so a cancelled pick
  ///   falls back to the prior source rather than serving nothing).
  /// - [save]: flushes the host's storage (no-op for nested screens).
  Future<D> decide({
    required String origin,
    required M effectiveMode,
    required D? Function(M mode, S? source) settled,
    required S? Function() currentSource,
    required Future<D> Function(String origin, M current) resolve,
    required void Function(D resolved) persist,
    required D Function(D resolved, S? fallbackSource) finalize,
    required Future<void> Function() save,
  }) async {
    final immediate = settled(effectiveMode, currentSource());
    if (immediate != null) return immediate;
    _inFlight ??= () async {
      final resolved = await resolve(origin, effectiveMode);
      persist(resolved);
      await save();
      return finalize(resolved, currentSource());
    }();
    try {
      return await _inFlight!;
    } finally {
      _inFlight = null;
    }
  }
}
