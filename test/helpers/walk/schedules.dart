import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';

import 'flows.dart';
import 'walk_runner.dart';

export 'flows.dart';

/// The platform's replies, held until something releases them: a schedule
/// in its chosen order, a walk's `Reply`, or a settle oldest first. Every
/// fake call a world makes waits here, tagged with the flow that made it.
final class Gate {
  final List<({PlatformCall call, int? flow, Completer<void> go})> _pending = [];

  /// Told of each call as it is made, with the flow that made it.
  void Function(PlatformCall call, {required int? flow})? onCall;

  Future<void> pace(PlatformCall call) {
    final go = Completer<void>();
    final flow = currentFlow();
    _pending.add((call: call, flow: flow, go: go));
    onCall?.call(call, flow: flow);
    return go.future;
  }

  List<PlatformCall> get pending => [for (final p in _pending) p.call];

  void release(int index) => _pending.removeAt(index).go.complete();
}

/// A world a schedule can drive: actions start without being waited on, and
/// every platform call goes through [gate]. Its [WalkWorld.settle] releases
/// replies oldest first until every action has finished.
abstract interface class ScheduledWorld<A> implements WalkWorld<A> {
  Gate get gate;

  /// Starts [action] as the next flow, numbered from 0 at [beginScript]
  /// (see [inFlow]), and returns at its first wait.
  void start(A action);

  /// Whether every action started has finished.
  bool get idle;

  /// The setup is done and settled; the script starts.
  void beginScript();

  /// The script ran to its end and held.
  void endScript();
}

/// Runs [script] after [setup] under every schedule with at most
/// [preemptions] preemptions, and fails on the first that breaks.
///
/// Each action of [script] starts a flow, and every platform call made in
/// its work, before or after any await, belongs to that flow. At each point
/// where every flow waits on a platform reply, the flow that moved last
/// goes on by default: its oldest pending reply lands. Anything else while
/// it has one pending (another flow's reply, or the next action arriving)
/// is a preemption. Once it has finished or waits on another flow, as on
/// the shared jar's turn, every pending reply and the next action are free
/// choices. So one preemption holds a flow at an await while another runs
/// to its end, the shape of every race found here; a bound on delays from
/// oldest-first would pay for each reply the other flow gets. [setup] runs
/// with every reply passing at once and settles after each action. Returns
/// the number of schedules run. The world's actions must land only between
/// replies, as an event does: Dart runs no input while microtasks remain.
Future<int> expectEveryScheduleHolds<A>({
  required ScheduledWorld<A> Function() world,
  required List<A> setup,
  required List<A> script,
  required int preemptions,
}) async {
  final taken = <int>[];
  final points = <_Point>[];
  var runs = 0;
  while (true) {
    final run = await _runSchedule(
      world: world,
      setup: setup,
      script: script,
      forced: taken,
    );
    runs++;
    for (var i = 0; i < taken.length; i++) {
      if (i >= run.points.length || run.points[i] != points[i]) {
        fail(
          'Replaying a schedule reached point $i as '
          '${i < run.points.length ? run.points[i] : 'nothing'}, not '
          '${points[i]}: the world is not deterministic.\n'
          'Setup: $setup\nScript: $script\nSchedule: ${run.trace.join(' | ')}',
        );
      }
    }
    for (var i = taken.length; i < run.points.length; i++) {
      taken.add(0);
      points.add(run.points[i]);
    }
    if (run.failure case final failure?) {
      fail(
        'A schedule broke: $failure\n'
        'Setup: $setup\nScript: $script\n'
        'Schedule (${_spent(taken: taken, points: points)} preemptions, '
        'each marked *; #n is the flow of the script\'s action n): '
        '${run.trace.join(' | ')}',
      );
    }
    while (taken.isNotEmpty) {
      final last = taken.length - 1;
      final point = points[last];
      final before =
          _spent(taken: taken, points: points) -
          (taken[last] > 0 && !point.free ? 1 : 0);
      if (taken[last] + 1 < point.options &&
          before + (point.free ? 0 : 1) <= preemptions) {
        taken[last]++;
        break;
      }
      taken.removeLast();
      points.removeLast();
    }
    if (taken.isEmpty) return runs;
  }
}

/// A choice point: how many options it had, which they were (each reply's
/// call and flow, or the next action), and whether taking any but the first
/// is free (the flow that moved last could not go on). A replay must meet the
/// same options, not only as many.
typedef _Point = ({int options, String labels, bool free});

int _spent({required List<int> taken, required List<_Point> points}) => [
  for (var i = 0; i < taken.length; i++)
    if (taken[i] > 0 && !points[i].free) i,
].length;

Future<({List<_Point> points, List<String> trace, String? failure})>
_runSchedule<A>({
  required ScheduledWorld<A> Function() world,
  required List<A> setup,
  required List<A> script,
  required List<int> forced,
}) {
  final result =
      Completer<({List<_Point> points, List<String> trace, String? failure})>();
  final points = <_Point>[];
  final trace = <String>[];
  final escaped = <Object>[];
  void finish(String? failure) {
    if (!result.isCompleted) {
      result.complete((points: points, trace: trace, failure: failure));
    }
  }

  unawaited(runZonedGuarded(() async {
    try {
      final w = world();
      for (final action in setup) {
        await w.apply(action);
        await w.settle();
      }
      w.beginScript();
      var next = 0;
      int? last;
      while (true) {
        await quiesce(w);
        if (escaped.isNotEmpty) return finish('${escaped.first}');
        final pending = w.gate._pending;
        final own = [
          for (var i = 0; i < pending.length; i++)
            if (pending[i].flow == last) i,
        ];
        // The options in order, the default first: a reply's index, or null
        // for the next action.
        final options = <int?>[
          ...own.take(1),
          for (var i = 0; i < pending.length; i++)
            if (own.isEmpty || i != own.first) i,
          if (next < script.length) null,
        ];
        if (options.isEmpty) break;
        final free = own.isEmpty;
        final at = points.length;
        final choice = at < forced.length ? forced[at] : 0;
        final labels = [
          for (final o in options)
            o == null ? '${script[next]}#$next' : '${pending[o].call.label}#${pending[o].flow}',
        ].join(', ');
        points.add((options: options.length, labels: labels, free: free));
        final mark = choice > 0 && !free ? '*' : '';
        if (options[choice] case final reply?) {
          final p = pending[reply];
          trace.add('$mark${p.call.label}#${p.flow}');
          last = p.flow;
          w.gate.release(reply);
        } else {
          final flow = next++;
          trace.add('$mark${script[flow]}#$flow');
          last = flow;
          w.start(script[flow]);
        }
      }
      if (!w.idle) {
        return finish(
          'a flow never finished with no reply pending '
          '(a wait nothing can end)',
        );
      }
      await w.settle();
      await quiesce(w);
      if (escaped.isEmpty) w.endScript();
      finish(escaped.isEmpty ? null : '${escaped.first}');
      // Known to throw: TestFailure (an Exception) from the world's
      // invariants, AssertionError from an owner's assert, and the Errors a
      // bug raises. Each fails the schedule.
    } on Exception catch (e) {
      finish(_reason(e));
    } on Error catch (e) {
      finish(_reason(e));
    }
  }, (error, stack) => escaped.add(_reason(error)),
      zoneSpecification: segmentRuns));
  return result.future;
}

String _reason(Object error) => switch (error) {
  TestFailure(:final message) => message ?? '$error',
  _ => '${error.runtimeType}: $error',
};

/// Lets every flow run until it waits on a held reply or finishes. A flow
/// between replies runs on microtasks, which one event turn drains; the
/// turns after it cover work the code puts on the event queue.
Future<void> quiesce(ScheduledWorld<Object?> world) async {
  await Future<void>(() {});
  for (var i = 0; i < 8 && world.gate.pending.isEmpty && !world.idle; i++) {
    await Future<void>(() {});
  }
}
