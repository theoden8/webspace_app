import 'dart:async';

/// One named step of the outgoing-site teardown.
class SiteTeardownStep {
  const SiteTeardownStep(this.name, this.run);

  final String name;
  final Future<void> Function() run;
}

/// What a [SiteTeardownEngine.quiesceOutgoing] run actually managed to do.
class SiteTeardownResult {
  const SiteTeardownResult({
    required this.ran,
    required this.errors,
    this.stalledOn,
    this.supersededBefore,
  });

  /// Steps that ran to completion, in order.
  final List<String> ran;

  /// Steps that threw, by name. A throwing step never stops the sequence.
  final Map<String, Object> errors;

  /// The step still in flight when the budget expired, if any.
  final String? stalledOn;

  /// The step the sequence stopped short of because a newer activation
  /// superseded this one, if any.
  final String? supersededBefore;

  bool get isClean =>
      errors.isEmpty && stalledOn == null && supersededBefore == null;
}

/// Quiesces the site the user is leaving — the step sequence shared by a site
/// switch and a return to the webspace list, extracted from
/// `_WebSpacePageState._setCurrentIndex` so the "what may abandon this
/// sequence, and what may it cost" rules can be exercised headlessly.
///
/// Every step is a native round-trip that can stall for as long as the page
/// wants: on iOS the per-instance pause freezes the page's JS thread (the
/// plugin's withheld-`alert()` hack), so a page some earlier pause left frozen
/// never answers `evaluateJavascript` again. The sequence therefore:
///
///   * runs steps in the caller's order (camera stop and media pause before
///     the pause — CAM-012 / BGAUDIO-009: anything dispatched after the freeze
///     never runs);
///   * treats a step that throws as best-effort and keeps going, so losing a
///     state capture doesn't cost the pause behind it;
///   * gives the whole sequence one budget and returns when it expires,
///     because the caller's own state change must not hinge on a native call
///     that may never answer.
///
/// A stalled step is abandoned, not cancelled — Dart cannot cancel a pending
/// platform-channel reply. The sequence keeps running in the background and
/// re-checks [superseded] before each remaining step, so a late-arriving reply
/// can't pause a webview that a newer activation has since resumed.
class SiteTeardownEngine {
  /// Long enough that a healthy `saveState()` + AES write on a slow device
  /// finishes inside it, short enough that a frozen page costs one stutter
  /// rather than the switch itself.
  static const Duration defaultBudget = Duration(seconds: 2);

  static Future<SiteTeardownResult> quiesceOutgoing({
    required List<SiteTeardownStep> steps,
    required bool Function() superseded,
    Duration budget = defaultBudget,
  }) async {
    final ran = <String>[];
    final errors = <String, Object>{};
    String? inFlight;
    String? supersededBefore;

    Future<void> runAll() async {
      for (final step in steps) {
        if (superseded()) {
          supersededBefore ??= step.name;
          return;
        }
        inFlight = step.name;
        try {
          await step.run();
          ran.add(step.name);
        } catch (e) {
          errors[step.name] = e;
        }
        inFlight = null;
      }
    }

    String? stalledOn;
    try {
      await runAll().timeout(budget);
    } on TimeoutException {
      stalledOn = inFlight;
    }

    return SiteTeardownResult(
      ran: List.unmodifiable(ran),
      errors: Map.unmodifiable(errors),
      stalledOn: stalledOn,
      supersededBefore: supersededBefore,
    );
  }
}
