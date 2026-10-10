import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'walk_rng.dart';

/// One app a walk drives, built fresh for every run of an action list.
abstract interface class WalkWorld<A> {
  /// Starts [action]; the work it starts may still be running on return.
  Future<void> apply(A action);

  /// Runs everything in flight to completion and checks what must hold
  /// whenever nothing is.
  Future<void> settle();

  /// What two runs of one action list must agree on after each step.
  String snapshot();
}

/// How one run of an action list ended.
sealed class WalkOutcome {
  const WalkOutcome({required this.trace});

  /// [WalkWorld.snapshot] after each step that completed.
  final List<String> trace;
}

final class WalkHeld extends WalkOutcome {
  const WalkHeld({required super.trace});
}

final class WalkBroke extends WalkOutcome {
  const WalkBroke({
    required super.trace,
    required this.step,
    required this.error,
    required this.stack,
  });

  /// The action that broke it, or the action count when the closing settle
  /// did.
  final int step;
  final Object error;
  final StackTrace stack;

  String get reason => switch (error) {
    TestFailure(:final message) => message ?? '$error',
    _ => '${error.runtimeType}: $error',
  };
}

/// Runs [actions] against a fresh [world], then settles it. An error from
/// work an action left running counts against the step it surfaced in.
Future<WalkOutcome> runActions<A>({
  required WalkWorld<A> Function() world,
  required List<A> actions,
}) {
  final outcome = Completer<WalkOutcome>();
  final escaped = <({Object error, StackTrace stack})>[];
  runZonedGuarded(() async {
    final trace = <String>[];
    WalkBroke broke(
      int step, {
      required Object error,
      required StackTrace stack,
    }) => WalkBroke(trace: trace, step: step, error: error, stack: stack);
    final WalkWorld<A> w;
    try {
      w = world();
    } on Error catch (e, s) {
      outcome.complete(broke(0, error: e, stack: s));
      return;
    }
    for (var i = 0; i <= actions.length; i++) {
      try {
        if (i < actions.length) {
          await w.apply(actions[i]);
        } else {
          await w.settle();
        }
        if (escaped.isNotEmpty) {
          outcome.complete(
            broke(i, error: escaped.first.error, stack: escaped.first.stack),
          );
          return;
        }
        trace.add(w.snapshot());
        // Known to throw: TestFailure (an Exception) from a world's
        // invariant, AssertionError from an owner's assert, and the Errors
        // a bug raises. Each is reported, never swallowed.
      } on Exception catch (e, s) {
        outcome.complete(broke(i, error: e, stack: s));
        return;
      } on Error catch (e, s) {
        outcome.complete(broke(i, error: e, stack: s));
        return;
      }
    }
    outcome.complete(WalkHeld(trace: trace));
  }, (error, stack) => escaped.add((error: error, stack: stack)));
  return outcome.future;
}

/// Delta-debugs [actions], which broke as [broke], down to a short list that
/// still breaks, within [budget] runs.
Future<({List<A> actions, WalkBroke broke})> shrinkWalk<A>({
  required WalkWorld<A> Function() world,
  required List<A> actions,
  required WalkBroke broke,
  int budget = 400,
}) async {
  List<A> upTo(List<A> list, {required WalkBroke broke}) =>
      list.sublist(0, math.min(broke.step + 1, list.length));
  var current = upTo(actions, broke: broke);
  var last = broke;
  var chunks = 2;
  var runs = 0;
  while (current.length >= 2 && runs < budget) {
    final size = (current.length / chunks).ceil();
    var reduced = false;
    for (
      var start = 0;
      start < current.length && runs < budget;
      start += size
    ) {
      final candidate = [
        ...current.sublist(0, start),
        ...current.sublist(math.min(start + size, current.length)),
      ];
      runs++;
      if (await runActions(world: world, actions: candidate)
          case final WalkBroke b) {
        current = upTo(candidate, broke: b);
        last = b;
        chunks = math.max(chunks - 1, 2);
        reduced = true;
        break;
      }
    }
    if (reduced) continue;
    if (chunks >= current.length) break;
    chunks = math.min(chunks * 2, current.length);
  }
  return (actions: current, broke: last);
}

/// One walk per seed: [length] actions drawn by [draw], run twice to prove
/// the run deterministic, then required to hold. A walk that breaks is
/// shrunk and fails with its seed and the shrunk list, which pastes as a
/// regression for [expectActionsHold].
Future<void> expectWalksHold<A>({
  required WalkWorld<A> Function() world,
  required A Function(WalkRng rng) draw,
  required Iterable<int> seeds,
  required int length,
}) async {
  for (final seed in seeds) {
    final rng = WalkRng(seed);
    await _expectHolds(
      world: world,
      actions: [for (var i = 0; i < length; i++) draw(rng)],
      origin: 'seed $seed',
    );
  }
}

/// [actions] must hold, and run the same way twice.
Future<void> expectActionsHold<A>({
  required WalkWorld<A> Function() world,
  required List<A> actions,
}) => _expectHolds(world: world, actions: actions, origin: 'regression');

Future<void> _expectHolds<A>({
  required WalkWorld<A> Function() world,
  required List<A> actions,
  required String origin,
}) async {
  final first = await runActions(world: world, actions: actions);
  final second = await runActions(world: world, actions: actions);
  final diverged = _divergence(first: first, second: second);
  if (diverged != null) {
    fail(
      'Walk ($origin) ran differently twice, so its seed would not '
      'reproduce it: $diverged\nActions: [${actions.join(', ')}]',
    );
  }
  if (first is! WalkBroke) return;
  final shrunk = await shrinkWalk(world: world, actions: actions, broke: first);
  fail(
    'Walk ($origin) broke at step ${first.step} of ${actions.length}: '
    '${first.reason}\n'
    'Shrunk to ${shrunk.actions.length} actions, which break at step '
    '${shrunk.broke.step}: ${shrunk.broke.reason}\n'
    '  [${shrunk.actions.join(', ')}]\n'
    '${shrunk.broke.stack}',
  );
}

String? _divergence({required WalkOutcome first, required WalkOutcome second}) {
  final (a, b) = (first, second);
  final n = math.min(a.trace.length, b.trace.length);
  for (var i = 0; i < n; i++) {
    if (a.trace[i] != b.trace[i]) {
      return 'after step $i:\n  ${a.trace[i]}\n  ${b.trace[i]}';
    }
  }
  return switch ((a, b)) {
    (WalkHeld(), WalkHeld()) when a.trace.length == b.trace.length => null,
    (
      WalkBroke(step: final s1, reason: final r1),
      WalkBroke(step: final s2, reason: final r2),
    )
        when s1 == s2 && r1 == r2 =>
      null,
    _ => 'one run ended ${_end(a)}, the other ${_end(b)}',
  };
}

String _end(WalkOutcome o) => switch (o) {
  WalkHeld() => 'held',
  WalkBroke(:final step, :final reason) => 'broken at $step ($reason)',
};

/// No limit while exploring with `WALK_SEEDS`, the default otherwise.
Timeout? get walkTimeout =>
    (int.tryParse(Platform.environment['WALK_SEEDS'] ?? '') ?? 0) > 0
    ? Timeout.none
    : null;

/// The seeds a walk test runs. CI runs [fixed], so a red run is always the
/// change's. `WALK_SEED=n` runs that one seed alone, to reproduce a failure;
/// `WALK_SEEDS=k` adds k fresh seeds after [fixed] and prints where they
/// start.
List<int> walkSeeds({required List<int> fixed}) {
  final env = Platform.environment;
  if (int.tryParse(env['WALK_SEED'] ?? '') case final seed?) return [seed];
  final extra = int.tryParse(env['WALK_SEEDS'] ?? '') ?? 0;
  if (extra <= 0) return fixed;
  final base = DateTime.now().microsecondsSinceEpoch;
  // ignore: avoid_print
  print('Walk exploration: $extra seeds from $base (rerun one with WALK_SEED)');
  return [...fixed, for (var i = 0; i < extra; i++) base + i];
}
