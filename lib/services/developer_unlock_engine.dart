/// Pure-Dart model of the tap-the-version-row unlock (the Android
/// developer-options gesture). Owns the counting and the three outcomes; the
/// host renders the message and persists the flag. See
/// test/developer_unlock_engine_test.dart.
library;

enum DeveloperUnlockOutcome {
  /// Below the countdown threshold: count silently.
  silent,

  /// Close enough that the user should be told how many taps remain.
  countdown,

  /// The last tap: developer mode turns on.
  unlocked,

  /// Already on, so the gesture has nothing left to do.
  alreadyEnabled,
}

class DeveloperUnlockStep {
  /// Tap count to carry into the next tap.
  final int taps;
  final DeveloperUnlockOutcome outcome;

  /// Taps still needed, meaningful only for [DeveloperUnlockOutcome.countdown].
  final int remaining;

  const DeveloperUnlockStep({
    required this.taps,
    required this.outcome,
    required this.remaining,
  });
}

class DeveloperUnlockEngine {
  /// Taps on the version row that turn developer mode on.
  static const int tapsToUnlock = 7;

  /// Taps after which the remaining count is announced. Below this the
  /// gesture stays invisible, so an accidental double tap says nothing.
  static const int countdownFrom = 3;

  /// Apply one tap. [taps] is the running count, [enabled] the current flag.
  static DeveloperUnlockStep tap({required int taps, required bool enabled}) {
    if (enabled) {
      return const DeveloperUnlockStep(
        taps: 0,
        outcome: DeveloperUnlockOutcome.alreadyEnabled,
        remaining: 0,
      );
    }
    final next = taps + 1;
    if (next >= tapsToUnlock) {
      // Reset so turning developer mode off and tapping again needs the full
      // gesture rather than one leftover tap.
      return const DeveloperUnlockStep(
        taps: 0,
        outcome: DeveloperUnlockOutcome.unlocked,
        remaining: 0,
      );
    }
    if (next >= countdownFrom) {
      return DeveloperUnlockStep(
        taps: next,
        outcome: DeveloperUnlockOutcome.countdown,
        remaining: tapsToUnlock - next,
      );
    }
    return DeveloperUnlockStep(
      taps: next,
      outcome: DeveloperUnlockOutcome.silent,
      remaining: tapsToUnlock - next,
    );
  }
}
