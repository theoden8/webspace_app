// The walk harness's own contract: a seed names one stream on every runner,
// a broken walk shrinks to what breaks it, a run that differs from itself is
// caught before its seed is trusted, and work an action leaves running
// cannot fail unseen.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/walk/walk_rng.dart';
import 'helpers/walk/walk_runner.dart';

/// Breaks once it has seen a 3 and, later, a 7.
final class _Planted implements WalkWorld<int> {
  final List<int> _seen = [];

  @override
  Future<void> apply(int action) async {
    if (action == 7 && _seen.contains(3)) throw StateError('3, then 7');
    _seen.add(action);
  }

  @override
  Future<void> settle() async {}

  @override
  String snapshot() => '$_seen';
}

int _drifts = 0;

/// Reads something outside the actions, so two runs of one list differ.
final class _Drifting implements WalkWorld<int> {
  _Drifting() : _run = _drifts++;

  final int _run;

  @override
  Future<void> apply(int action) async {}

  @override
  Future<void> settle() async {}

  @override
  String snapshot() => 'run $_run';
}

/// Action 1 starts work that fails after the action has returned.
final class _Escaping implements WalkWorld<int> {
  @override
  Future<void> apply(int action) async {
    if (action == 1) unawaited(Future<void>.error(StateError('escaped')));
  }

  @override
  Future<void> settle() async {}

  @override
  String snapshot() => '';
}

void main() {
  test('SplitMix64 gives the published stream for seed 1234567', () {
    final rng = WalkRng(1234567);
    expect(
      [for (var i = 0; i < 5; i++) rng.nextUint64()],
      [
        6457827717110365317,
        3203168211198807973,
        -8629252141511181193, // 9817491932198370423 as unsigned
        4593380528125082431,
        -2037821214251327795, // 16408922859458223821 as unsigned
      ],
    );
  });

  test('nextInt stays below its bound and pick draws only weighted keys', () {
    final rng = WalkRng(7);
    final ints = [for (var i = 0; i < 1000; i++) rng.nextInt(5)];
    expect(ints.toSet(), {0, 1, 2, 3, 4});
    final picks = {
      for (var i = 0; i < 200; i++) rng.pick({'a': 1, 'b': 3}),
    };
    expect(picks, {'a', 'b'});
  });

  test('a broken walk shrinks to the two actions that break it', () async {
    const filler = [0, 1, 2, 4, 5, 6, 8, 9];
    final rng = WalkRng(11);
    List<int> noise(int n) => [
      for (var i = 0; i < n; i++) filler[rng.nextInt(filler.length)],
    ];
    final actions = [...noise(25), 3, ...noise(20), 7, ...noise(15)];

    final broke = await runActions(world: _Planted.new, actions: actions);
    expect(broke, isA<WalkBroke>());
    final shrunk = await shrinkWalk(
      world: _Planted.new,
      actions: actions,
      broke: broke as WalkBroke,
    );
    expect(shrunk.actions, [3, 7]);
    expect(shrunk.broke.reason, contains('3, then 7'));
  });

  test(
    'a walk that runs differently twice fails before its seed is trusted',
    () async {
      await expectLater(
        expectActionsHold(world: _Drifting.new, actions: const [1, 2]),
        throwsA(
          isA<TestFailure>().having(
            (f) => f.message,
            'message',
            contains('ran differently twice'),
          ),
        ),
      );
    },
  );

  test('an error from work an action left running breaks the walk', () async {
    final outcome = await runActions(
      world: _Escaping.new,
      actions: const [0, 1, 0, 0],
    );
    expect(
      outcome,
      isA<WalkBroke>().having((b) => b.reason, 'reason', contains('escaped')),
    );
  });
}
