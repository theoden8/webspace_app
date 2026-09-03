import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/developer_unlock_engine.dart';

void main() {
  group('DeveloperUnlockEngine', () {
    /// Tap [n] times from a cold counter, returning every step.
    List<DeveloperUnlockStep> run(int n, {bool enabled = false}) {
      final steps = <DeveloperUnlockStep>[];
      var taps = 0;
      for (var i = 0; i < n; i++) {
        final step = DeveloperUnlockEngine.tap(taps: taps, enabled: enabled);
        taps = step.taps;
        steps.add(step);
      }
      return steps;
    }

    test('the seventh tap unlocks, and no earlier one does', () {
      final steps = run(DeveloperUnlockEngine.tapsToUnlock);
      expect(
        steps.take(DeveloperUnlockEngine.tapsToUnlock - 1)
            .every((s) => s.outcome != DeveloperUnlockOutcome.unlocked),
        isTrue,
      );
      expect(steps.last.outcome, DeveloperUnlockOutcome.unlocked);
    });

    test('the first taps say nothing, so a stray double tap is silent', () {
      final steps = run(DeveloperUnlockEngine.countdownFrom - 1);
      expect(steps.every((s) => s.outcome == DeveloperUnlockOutcome.silent),
          isTrue);
    });

    test('the countdown reaches 1 on the tap before the last', () {
      final steps = run(DeveloperUnlockEngine.tapsToUnlock - 1);
      expect(steps.last.outcome, DeveloperUnlockOutcome.countdown);
      expect(steps.last.remaining, 1);
    });

    test('the counter resets on unlock, so turning it back off needs the '
        'whole gesture again', () {
      final steps = run(DeveloperUnlockEngine.tapsToUnlock);
      expect(steps.last.taps, 0);
      // One tap after a disable must not re-unlock.
      final next = DeveloperUnlockEngine.tap(taps: steps.last.taps, enabled: false);
      expect(next.outcome, isNot(DeveloperUnlockOutcome.unlocked));
    });

    test('tapping while enabled reports that and never counts', () {
      for (final step in run(3, enabled: true)) {
        expect(step.outcome, DeveloperUnlockOutcome.alreadyEnabled);
        expect(step.taps, 0);
      }
    });
  });
}
