import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/screen_share.dart';

/// Per-site screen-sharing resolution, on top of the shared
/// [MediaGrantEngine] funnel (decide → coalesce → persist), which also carries
/// the backgrounded-site gate (SHARE-011).
class ScreenShareDecisionEngine {
  final MediaGrantEngine<ScreenShareMode, VirtualScreenSource,
      ScreenShareDecision> _engine = MediaGrantEngine();

  /// Resolve a request for [origin].
  ///
  /// - [isSiteActive]: whether the requesting site is the one on screen. A
  ///   backgrounded site is denied outright (SHARE-011), for CAM-011's first
  ///   reason: a "share your screen?" dialog naming an origin the user is not
  ///   looking at reads as belonging to the site that is on screen, and screen
  ///   sharing is the grant a user is least willing to misattribute.
  /// - [effectiveMode]: the site's current mode with archive-tier already
  ///   applied by the caller. `block` resolves immediately; `virtual` resolves
  ///   immediately once [currentSource] is non-null.
  /// - [currentSource]: reads the site's picked surface media (may change
  ///   after [persist]).
  /// - [resolve]: host UI — shows the Block / Use-a-media-file popup or the
  ///   file picker and returns the user's choice. Only invoked for an
  ///   unresolved `ask`, or a `virtual` site with no source yet.
  /// - [persist]: applies the resolved mode (always) and source (only when
  ///   non-null, so a cancelled pick leaves the prior source intact) to the
  ///   host's storage.
  /// - [save]: flushes the host's storage (no-op for nested screens).
  Future<ScreenShareDecision> decide({
    required String origin,
    required bool Function() isSiteActive,
    required ScreenShareMode effectiveMode,
    required VirtualScreenSource? Function() currentSource,
    required Future<ScreenShareDecision> Function(
            String origin, ScreenShareMode current)
        resolve,
    required void Function(ScreenShareMode mode, VirtualScreenSource? source)
        persist,
    required Future<void> Function() save,
  }) =>
      _engine.decide(
        origin: origin,
        isSiteActive: isSiteActive,
        denied: () => const ScreenShareDecision.block(),
        effectiveMode: effectiveMode,
        settled: (mode, source) {
          if (mode == ScreenShareMode.block) {
            return const ScreenShareDecision.block();
          }
          if (mode == ScreenShareMode.virtual && source != null) {
            return ScreenShareDecision(mode, source);
          }
          return null;
        },
        currentSource: currentSource,
        resolve: resolve,
        persist: (d) => persist(d.mode, d.source),
        finalize: (d, fallback) =>
            ScreenShareDecision(d.mode, d.source ?? fallback),
        save: save,
      );
}
