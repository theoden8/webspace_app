// The schedule enumerator (test/helpers/walk/schedules.dart) on a toy world
// whose schedules can be counted by hand, so a harness that explores too few
// or too many interleavings fails here, before it vouches for the app.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';

import 'helpers/walk/schedules.dart';

sealed class Toy {
  const Toy(this.replies);

  /// The platform replies the flow waits on.
  final int replies;
}

/// Waits on its replies and touches nothing shared.
final class Wait extends Toy {
  const Wait(super.replies);

  @override
  String toString() => 'wait$replies';
}

/// Reads the counter, waits on its replies, then writes what it read plus
/// one: two that overlap lose an update.
final class Inc extends Toy {
  const Inc(super.replies);

  @override
  String toString() => 'inc$replies';
}

final class ToyWorld implements ScheduledWorld<Toy> {
  ToyWorld({required this.nondeterministic});

  /// Waits on another call on every other run, as a world that reads a
  /// clock or a random number would.
  final bool nondeterministic;
  static int _runs = 0;

  @override
  final Gate gate = Gate();
  int counter = 0;
  int _incs = 0;
  int _started = 0;
  int _running = 0;
  bool _scripting = false;

  Future<void> _run(Toy action) async {
    _running++;
    final read = counter;
    for (var i = 0; i < action.replies; i++) {
      // Any two calls: the toy only needs the replies told apart.
      await gate.pace(
        nondeterministic && _runs.isOdd ? PlatformCall.webViewPause : PlatformCall.webViewResume,
      );
    }
    if (action is Inc) counter = read + 1;
    _running--;
  }

  @override
  void start(Toy action) {
    final flow = _started++;
    if (action is Inc) _incs++;
    unawaited(inFlow(() => _run(action), flow: flow));
  }

  @override
  bool get idle => _running == 0;

  @override
  void beginScript() {
    _runs++;
    _started = 0;
    _incs = 0;
    counter = 0;
    _scripting = true;
  }

  @override
  void endScript() {
    expect(counter, _incs, reason: 'an increment was lost');
  }

  @override
  Future<void> apply(Toy action) async => start(action);

  @override
  Future<void> settle() async {
    while (!idle || gate.pending.isNotEmpty) {
      if (gate.pending.isNotEmpty) gate.release(0);
      await Future<void>(() {});
    }
  }

  @override
  String snapshot() => '$counter ${_scripting ? 'script' : 'setup'}';
}

Future<int> _runs({
  required List<Toy> script,
  required int preemptions,
  bool nondeterministic = false,
}) =>
    expectEveryScheduleHolds<Toy>(
      world: () => ToyWorld(nondeterministic: nondeterministic),
      setup: const [],
      script: script,
      preemptions: preemptions,
    );

void main() {
  // Two flows of one reply each have three interleavings that start them in
  // order: A runs to its end (no preemption); B starts and finishes before
  // A's reply (one: starting B while A waits); and B starts, then A's reply
  // lands before B's (two: that and taking A's reply while B waits).
  group('counted by hand', () {
    test('one flow has one schedule', () async {
      expect(await _runs(script: const [Wait(3)], preemptions: 2), 1);
    });

    test('two one-reply flows: 1, then 2, then all 3 schedules', () async {
      const script = [Wait(1), Wait(1)];
      expect(await _runs(script: script, preemptions: 0), 1);
      expect(await _runs(script: script, preemptions: 1), 2);
      expect(await _runs(script: script, preemptions: 2), 3);
      expect(await _runs(script: script, preemptions: 5), 3);
    });
  });

  test('a lost update hides at no preemption and shows at one', () async {
    expect(await _runs(script: const [Inc(1), Inc(1)], preemptions: 0), 1);
    await expectLater(
      _runs(script: const [Inc(1), Inc(1)], preemptions: 1),
      throwsA(isA<TestFailure>().having(
          (f) => f.message, 'message', contains('an increment was lost'))),
    );
  });

  test('a world that varies between runs is refused', () async {
    await expectLater(
      _runs(script: const [Wait(1), Wait(1)], preemptions: 1, nondeterministic: true),
      throwsA(isA<TestFailure>().having(
          (f) => f.message, 'message', contains('not deterministic'))),
    );
  });
}
