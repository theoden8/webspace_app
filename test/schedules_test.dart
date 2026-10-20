// The schedule enumerator (test/helpers/walk/schedules.dart) on a toy world
// whose schedules can be counted by hand, so a harness that explores too few
// or too many interleavings fails here, before it vouches for the app. The
// toy marks its steps as the engines do, named after three of the tables'
// steps but read by a relation of its own (_toyCommutes): a flow's input
// and its replies touch nothing shared, and an increment's read and write
// touch the counter.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stack_trace/stack_trace.dart';
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
    ActivationSteps.mark(action is Inc ? _counter : _input);
    for (var i = 0; i < action.replies; i++) {
      // Any two calls: the toy only needs the replies told apart.
      await gate.pace(
        nondeterministic && _runs.isOdd ? PlatformCall.webViewPause : PlatformCall.webViewResume,
      );
      ActivationSteps.mark(_reply);
    }
    if (action is Inc) {
      counter = read + 1;
      ActivationSteps.mark(_counter);
    }
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
  ActivationStep? inputOf(Toy action) => switch (action) {
    Wait() => _input,
    Inc() => _counter,
  };

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

/// The toy's steps: a flow's input, a reply, and an increment's read or
/// write of the counter, the only step that meets another.
const _input = ActivationStep.tap;
const _reply = ActivationStep.resumeReply;
const _counter = ActivationStep.plan;

bool _toyCommutes(ActivationStep a, {required ActivationStep other}) =>
    a != _counter || other != _counter;

Future<int> _runs({
  required List<Toy> script,
  required int preemptions,
  bool nondeterministic = false,
}) async =>
    (await expectEveryScheduleHolds<Toy>(
      world: () => ToyWorld(nondeterministic: nondeterministic),
      setup: const [],
      script: script,
      preemptions: preemptions,
      commutes: null,
    )).runs;

Future<ScheduleSearch> _search({
  required List<Toy> script,
  required int preemptions,
  required Commutes? commutes,
}) => exploreSchedules<Toy>(
  world: () => ToyWorld(nondeterministic: false),
  setup: const [],
  script: script,
  preemptions: preemptions,
  commutes: commutes,
  toTheEnd: true,
);

void main() {
  test(
    'diagnostic stack chains preserve schedules and counterexamples',
    () async {
      var scripts = <List<Toy>>[[]];
      for (var length = 1; length <= 3; length++) {
        scripts = [
          for (final prefix in scripts)
            for (final action in const [Wait(1), Wait(2), Inc(1), Inc(2)])
              [...prefix, action],
        ];
        for (final script in scripts) {
          for (final preemptions in [0, 1, 2]) {
            for (final commutes in <Commutes?>[null, _toyCommutes]) {
              Future<ScheduleSearch> search() => _search(
                script: script,
                preemptions: preemptions,
                commutes: commutes,
              );
              final chained = await search();
              final native = await Chain.disable(search);
              expect(
                (native.runs, native.stopped),
                (chained.runs, chained.stopped),
              );
              expect(native.ends, chained.ends);
              expect(native.failures, chained.failures);
            }
          }
        }
      }
    },
  );

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

  group('reduced by sleep sets', () {
    // The second schedule above only swaps two flows that share nothing,
    // so the reduced search stops it short; the third is the first's
    // tail swapped, and never runs.
    test('two one-reply flows that share nothing: one schedule and one '
        'stopped', () async {
      final search = await _search(
        script: const [Wait(1), Wait(1)],
        preemptions: 2,
        commutes: _toyCommutes,
      );
      expect((search.runs, search.stopped), (1, 1));
      expect(search.ends, {'0 script'});
    });

    test('the lost update still shows at one preemption', () async {
      final search = await _search(
        script: const [Inc(1), Inc(1)],
        preemptions: 1,
        commutes: _toyCommutes,
      );
      expect(search.failures.keys, [contains('an increment was lost')]);
    });

    // Sleep sets keep every end and every failure, a bound on preemptions
    // included: only a flow's default reply sleeps, and moving it ahead
    // never spends a preemption the schedule pruned did not.
    for (final script in const [
      [Inc(1), Wait(2), Inc(1)],
      [Wait(2), Inc(2), Inc(1)],
      [Inc(2), Inc(2), Wait(1)],
      [Wait(1), Wait(2), Wait(1)],
    ]) {
      for (final preemptions in [1, 2, 3]) {
        test('$script at $preemptions: the same ends and failures, from '
            'fewer schedules', () async {
          final every = await _search(
            script: script,
            preemptions: preemptions,
            commutes: null,
          );
          final reduced = await _search(
            script: script,
            preemptions: preemptions,
            commutes: _toyCommutes,
          );
          expect(reduced.ends, every.ends);
          expect(reduced.failures.keys.toSet(), every.failures.keys.toSet());
          expect(reduced.runs + reduced.stopped, lessThan(every.runs));
        });
      }
    }
  });

  test('a world that varies between runs is refused', () async {
    await expectLater(
      _runs(script: const [Wait(1), Wait(1)], preemptions: 1, nondeterministic: true),
      throwsA(isA<TestFailure>().having(
          (f) => f.message, 'message', contains('not deterministic'))),
    );
  });
}
