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
  /// onto a single popup / file-pick. Keyed by prompt origin so a subframe
  /// never rides the answer the user gave for the top document, and cleared
  /// once each decision settles.
  final Map<String, Future<D>> _inFlight = {};

  /// A subframe's answer is deliberately not persisted, but it still has to
  /// outlive the popup that produced it by a moment: allowing a frame makes the
  /// shim call the real `getUserMedia`, and the platform permission request
  /// that follows arrives milliseconds later for the same origin. Without a
  /// grace window the user answers the same question twice, once in our popup
  /// and once behind it. Keyed by prompt origin, so it can only ever hand back
  /// the answer given for that exact frame.
  final Map<String, (DateTime, D)> _recentSubframe = {};

  static const Duration _subframeGrace = Duration(seconds: 30);

  /// Resolve a request for [origin].
  ///
  /// - [isSiteActive]: whether the requesting site is the one on screen. A
  ///   backgrounded site is denied outright (CAM-011 / MIC-011): its popup
  ///   would be read as coming from the site the user is looking at, and a
  ///   remembered grant would start capture with nothing on screen to
  ///   attribute it to. Required rather than optional so a new capture
  ///   feature — or a new call site for an existing one — cannot be wired up
  ///   without answering it. Only the grant is gated: the non-prompting mode
  ///   read behind `enumerateDevices` does not come through here, since the
  ///   shims cache it per document and gating it would strand a site that
  ///   enumerated while backgrounded.
  /// - [denied]: the decision handed back for a backgrounded site.
  /// - [isTopFrame]: whether the request came from the top document. A
  ///   subframe's answer is used for that request and never written back to
  ///   the site: the popup the user answered named the frame, not the site,
  ///   so it cannot be what flips the site's own mode (CAM-014 / MIC-016).
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
    required bool Function() isSiteActive,
    required bool isTopFrame,
    required D Function() denied,
    required M effectiveMode,
    required D? Function(M mode, S? source) settled,
    required S? Function() currentSource,
    required Future<D> Function(String origin, M current) resolve,
    required void Function(D resolved) persist,
    required D Function(D resolved, S? fallbackSource) finalize,
    required Future<void> Function() save,
  }) async {
    if (!isSiteActive()) return denied();
    final immediate = settled(effectiveMode, currentSource());
    if (immediate != null) return immediate;
    if (!isTopFrame) {
      final recent = _takeRecentSubframe(origin);
      if (recent != null) return recent;
    }
    final pending = _inFlight[origin] ??= () async {
      final resolved = await resolve(origin, effectiveMode);
      if (isTopFrame) {
        persist(resolved);
        await save();
      } else {
        _recentSubframe[origin] = (DateTime.now(), resolved);
      }
      return finalize(resolved, currentSource());
    }();
    try {
      return await pending;
    } finally {
      _inFlight.remove(origin);
    }
  }

  /// The answer given for [origin] inside the grace window, if any. Expired
  /// entries are dropped as they are found rather than on a timer.
  D? _takeRecentSubframe(String origin) {
    final now = DateTime.now();
    _recentSubframe.removeWhere(
      (_, e) => now.difference(e.$1) > _subframeGrace,
    );
    final hit = _recentSubframe[origin];
    return hit == null ? null : hit.$2;
  }
}

/// The mode a nested screen starts from. `real` is the one answer that opens
/// the device, and the popup that produced it named the parent's top
/// document; a page reached through a link is asked for itself
/// (CAM-005 / MIC-005). Every other mode is inherited as it is.
T nestedSeedMode<T>(T mode, {required T real, required T ask}) =>
    mode == real ? ask : mode;
