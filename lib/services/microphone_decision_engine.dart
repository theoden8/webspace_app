import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/microphone.dart';

/// Per-site microphone-request resolution, on top of the shared
/// [MediaGrantEngine] funnel (decide → coalesce → persist), which also
/// carries the backgrounded-site gate (MIC-011).
class MicrophoneDecisionEngine {
  final MediaGrantEngine<MicrophoneAccessMode, VirtualMicrophoneSource,
      MicrophoneDecision> _engine = MediaGrantEngine();

  /// Resolve a request for [origin].
  ///
  /// - [isSiteActive]: whether the requesting site is the one on screen. A
  ///   backgrounded site is denied outright (MIC-011): its popup would be read
  ///   as coming from the site the user is looking at. There is no device to
  ///   protect here — the clip is a local file — but the popup's attribution
  ///   problem is the camera's exactly, so the answer is the camera's too.
  /// - [isTopFrame]: whether the top document is what asked. `real` hands over
  ///   the device mic under the MIC-014 containment contract, and the popup
  ///   that produced it named the top document — so a subframe does not
  ///   inherit it and is asked separately, under its own origin (MIC-016). The
  ///   device-free answers are inherited as they are: `block` denies, and
  ///   `virtual` loops the clip the user picked, which records nothing.
  /// - [effectiveMode]: the site's current mode with archive-tier already
  ///   applied by the caller. `block` resolves immediately, `real` immediately
  ///   for the top document; `virtual` resolves immediately once
  ///   [currentSource] is non-null.
  /// - [currentSource]: reads the site's picked audio clip (may change after
  ///   [persist]).
  /// - [resolve]: host UI — shows the Block/Use-audio-file popup or the file
  ///   picker and returns the user's choice. Only invoked for an unresolved
  ///   `ask`, or a `virtual` site with no clip yet.
  /// - [persist]: applies the resolved mode (always) and source (only when
  ///   non-null, so a cancelled pick leaves the prior clip intact) to the
  ///   host's storage.
  /// - [save]: flushes the host's storage (no-op for nested screens).
  Future<MicrophoneDecision> decide({
    required String origin,
    required bool Function() isSiteActive,
    required bool isTopFrame,
    required MicrophoneAccessMode effectiveMode,
    required VirtualMicrophoneSource? Function() currentSource,
    required Future<MicrophoneDecision> Function(
            String origin, MicrophoneAccessMode current)
        resolve,
    required void Function(
            MicrophoneAccessMode mode, VirtualMicrophoneSource? source)
        persist,
    required Future<void> Function() save,
  }) =>
      _engine.decide(
        origin: origin,
        isSiteActive: isSiteActive,
        isTopFrame: isTopFrame,
        denied: () => const MicrophoneDecision.block(),
        effectiveMode: effectiveMode,
        settled: (mode, source) {
          if (mode == MicrophoneAccessMode.real) {
            return isTopFrame
                ? const MicrophoneDecision(MicrophoneAccessMode.real)
                : null;
          }
          if (mode == MicrophoneAccessMode.block) {
            return const MicrophoneDecision.block();
          }
          if (mode == MicrophoneAccessMode.virtual && source != null) {
            return MicrophoneDecision(mode, source);
          }
          return null;
        },
        currentSource: currentSource,
        resolve: resolve,
        persist: (d) => persist(d.mode, d.source),
        finalize: (d, fallback) =>
            MicrophoneDecision(d.mode, d.source ?? fallback),
        save: save,
      );
}
