import 'package:flutter/foundation.dart';

/// Debug-only switch that drops named Dart-side repaint triggers.
///
/// BUG-001 gap #5 is an open question, not a modelling hole: every warm-start
/// repaint since Attempt 8 keys on `didChangeMetrics`, a signal that
/// *correlates* with the webview SurfaceView reattach but is not it (Flutter
/// can dedupe identical window metrics, and the callback tracks the main
/// FlutterView). On a device where it does not fire, Attempt 8 is a no-op and
/// the screen stays blank — and nothing in the suite can tell that device from
/// a healthy one, because on the emulator the proxy always fires.
///
/// Suppressing the Dart triggers by name simulates exactly that device: what
/// is left is whatever the native layer does on its own. It is the runnable
/// half of `formal/warmstart.tla`'s `Fix="proxy"` vs `Fix="attach"` split, and
/// the instrument for deciding whether a native attach callback in the fork is
/// worth adopting.
///
/// Gated on [kReleaseMode] and never set outside the diag tiers, so a release
/// build cannot lose a repaint to it. Profile builds are in scope on purpose:
/// they are what the tier needs to drive an AOT, non-inspectable webview, the
/// two things a shipped build has and a debug build does not.
class RepaintSuppression {
  RepaintSuppression._();

  static Set<String> _triggers = const <String>{};

  /// Trigger labels currently dropped. Empty in every ordinary build.
  static Set<String> get triggers => _triggers;

  /// Replace the suppressed set. No-op in release builds.
  static void set(Iterable<String> triggers) {
    if (kReleaseMode) return;
    _triggers = Set<String>.unmodifiable(triggers.map((t) => t.trim()).where(
          (t) => t.isNotEmpty,
        ));
  }

  /// Parse a comma-separated list (`resume,metrics-resume`) from a launch
  /// extra or environment variable.
  static void setFromSpec(String? spec) {
    if (spec == null || spec.trim().isEmpty) {
      set(const <String>[]);
      return;
    }
    set(spec.split(','));
  }

  /// Whether [trigger] is currently dropped.
  static bool suppresses(String trigger) =>
      !kReleaseMode && _triggers.contains(trigger);

  @visibleForTesting
  static void reset() => _triggers = const <String>{};
}
