import 'dart:async';

import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';

import 'flows.dart';
import 'walk_runner.dart';

export 'flows.dart';

/// The platform's replies, held until something releases them: a schedule
/// in its chosen order, a walk's `Reply`, or a settle oldest first. Every
/// fake call a world makes waits here, tagged with the flow that made it
/// and how many that flow made before it.
final class Gate {
  final List<_Held> _pending = [];

  /// How many calls each flow has made, counted again from the script's
  /// start so a call is named the same in every run that makes it.
  final Map<int?, int> _made = {};

  /// Told of each call as it is made, with the flow that made it.
  void Function(PlatformCall call, {required int? flow})? onCall;

  Future<void> pace(PlatformCall call) {
    final go = Completer<void>();
    final flow = currentFlow();
    final nth = _made[flow] = (_made[flow] ?? 0) + 1;
    _pending.add((call: call, move: (flow: flow, nth: nth), go: go));
    if (!onTheClock) _log?.add((flow: flow, what: call));
    onCall?.call(call, flow: flow);
    return go.future;
  }

  List<PlatformCall> get pending => [for (final p in _pending) p.call];

  void release(int index) => _pending.removeAt(index).go.complete();
}

typedef _Held = ({PlatformCall call, _Move move, Completer<void> go});

/// A choice a schedule makes, named so that another run knows it again:
/// the reply to the [nth] call [flow] made since the script began, or, as
/// 0, the arrival of the script's action that starts [flow].
typedef _Move = ({int? flow, int nth});

/// The flows whose code ran since a search last looked, while one looks.
Set<int?>? _running;

/// What ran since a search last looked, in order, while one looks: each
/// step a flow marked and each call it made.
List<_Event>? _log;

/// A step a flow marked ([ActivationStep]) or a call it made
/// ([PlatformCall]).
typedef _Event = ({int? flow, Enum what});

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

  /// The step [action]'s input is, or null for one no table holds: what a
  /// reduced search takes its arrival for when it marks nothing, an input
  /// the world or the code dropped, which reads only what that step's
  /// guard does.
  ActivationStep? inputOf(A action);
}

/// Which two steps the code marks run in either order to one state: what
/// a reduced search ([exploreSchedules]) takes for independent. A step it
/// knows nothing of commutes with none.
typedef Commutes =
    bool Function(ActivationStep a, {required ActivationStep other});

/// Runs [script] after [setup] under every schedule with at most
/// [preemptions] preemptions, or, with [commutes], under enough of them to
/// reach every end state and every failure those reach, and fails on the
/// first that breaks.
///
/// Each action of [script] starts a flow, and every platform call made in
/// its work, before or after any await, belongs to that flow. At each point
/// where every flow waits on a platform reply, the flow that moved last
/// goes on by default: its oldest pending reply lands. Anything else while
/// it has one pending (another flow's reply, or the next action arriving)
/// is a preemption. Once it has finished or waits on another flow, as on
/// the shared jar's turn, every pending reply and the next action are free
/// choices. So one preemption holds a flow at an await while another runs
/// to its end, the shape of most races found here, and two let the held
/// flow cut into the other and the other finish after it; a bound on
/// delays from oldest-first would pay for each reply the other flow gets.
/// [setup] runs with every reply passing at once and settles after each
/// action. Returns what the search met. The world's actions must land only
/// between replies, as an event does: Dart runs no input while microtasks
/// remain.
Future<ScheduleSearch> expectEveryScheduleHolds<A>({
  required ScheduledWorld<A> Function() world,
  required List<A> setup,
  required List<A> script,
  required int preemptions,
  required Commutes? commutes,
}) async {
  final search = await exploreSchedules(
    world: world,
    setup: setup,
    script: script,
    preemptions: preemptions,
    commutes: commutes,
    toTheEnd: false,
  );
  if (search.failures.entries.firstOrNull
      case MapEntry(key: final reason, value: final schedule)?) {
    fail(
      'A schedule broke: $reason\n'
      'Setup: $setup\nScript: $script\n'
      'Schedule ($schedule',
    );
  }
  return search;
}

/// What a search of the schedules met: how many it ran to their end and how
/// many it stopped with every option left asleep ([exploreSchedules]); the
/// world's state at the end of each it ran to its end
/// ([WalkWorld.snapshot]); and each way one broke, with the first schedule
/// that broke so.
typedef ScheduleSearch = ({
  int runs,
  int stopped,
  Set<String> ends,
  Map<String, String> failures,
});

/// Every schedule of [script] after [setup] with at most [preemptions]
/// preemptions ([expectEveryScheduleHolds] says what counts), depth first,
/// the default option first; [toTheEnd] goes on past the first failure.
///
/// With [commutes] the search prunes by sleep sets (Godefroid, 1996): once
/// a flow's default reply has been explored at a point, each sibling that
/// runs only steps that commute with what that reply ran leaves it asleep,
/// and no schedule below takes it until a step that does not commute with
/// it runs. A schedule that would is the explored one with the reply moved
/// ahead of the steps it slept through, which ends in the same state. Only
/// the default sleeps: moving it ahead never spends a preemption, so the
/// schedule kept is within the bound whenever the one pruned is, where
/// moving any other option ahead can change which flow moved last and
/// spend one more. A choice is told by what ran in it: every flow whose
/// code ran and the steps they marked; a flow that called after its last
/// mark is inside the step it marks next, taken as each step declaring
/// those calls; a script flow that marked nothing and waits on nothing new
/// is its input, dropped ([ScheduledWorld.inputOf]); and any other flow
/// that ran unmarked commutes with nothing.
Future<ScheduleSearch> exploreSchedules<A>({
  required ScheduledWorld<A> Function() world,
  required List<A> setup,
  required List<A> script,
  required int preemptions,
  required Commutes? commutes,
  required bool toTheEnd,
}) async {
  final search = _Search(bound: preemptions, commutes: commutes);
  var runs = 0;
  var stopped = 0;
  final ends = <String>{};
  final failures = <String, String>{};
  do {
    final run = await _runSchedule(
      world: world,
      setup: setup,
      script: script,
      chooser: search,
    );
    if (search.diverged case final diverged?) {
      fail(
        '$diverged: the world is not deterministic.\n'
        'Setup: $setup\nScript: $script\nSchedule: ${run.trace.join(' | ')}',
      );
    }
    switch (run.outcome) {
      case _Reached(:final state):
        runs++;
        ends.add(state);
      case _Broke(:final reason):
        runs++;
        failures.putIfAbsent(
          reason,
          () =>
              '${search.spent} preemptions, each marked *; #n is the flow of '
              'the script\'s action n): ${run.trace.join(' | ')}',
        );
        if (!toTheEnd) {
          return (runs: runs, stopped: stopped, ends: ends, failures: failures);
        }
      case _Stopped():
        stopped++;
    }
  } while (search.advance());
  return (runs: runs, stopped: stopped, ends: ends, failures: failures);
}

/// What one choice ran: every flow whose code ran in it, and the steps
/// they marked or are inside; null steps when some of it is no step's.
typedef _Ran = ({Set<int?> flows, Set<ActivationStep>? steps});

bool _independent(
  _Ran a, {
  required _Ran other,
  required Commutes commutes,
}) {
  final (x, y) = (a.steps, other.steps);
  if (x == null || y == null || a.flows.any(other.flows.contains)) {
    return false;
  }
  return x.every((s) => y.every((t) => commutes(s, other: t)));
}

bool _same(_Ran a, {required _Ran other}) =>
    a.flows.length == other.flows.length &&
    a.flows.containsAll(other.flows) &&
    switch ((a.steps, other.steps)) {
      (null, null) => true,
      (final x?, final y?) => x.length == y.length && x.containsAll(y),
      _ => false,
    };

/// What a choice that [mover] took ran, from the flows whose code ran
/// ([flows]), what they marked and called ([log]), the call whose reply it
/// was ([released], null for an arrival), the flows that marked a step
/// before it ([begun]) and the input that starts each of the script's
/// flows ([inputs]); [exploreSchedules] says how.
_Ran _ranOf({
  required int? mover,
  required Set<int?> flows,
  required PlatformCall? released,
  required List<_Event> log,
  required Set<int?> begun,
  required List<ActivationStep?> inputs,
}) {
  final all = {mover, ...flows, for (final e in log) e.flow};
  final steps = <ActivationStep>{};
  ActivationStep? inputOf(int? f) => switch (f) {
    final i? when i >= 0 && i < inputs.length && !begun.contains(f) =>
      inputs[i],
    _ => null,
  };
  for (final f in all) {
    final mine = [
      for (final e in log)
        if (e.flow == f) e.what,
    ];
    final last = mine.lastIndexWhere((w) => w is ActivationStep);
    steps.addAll(mine.whereType<ActivationStep>());
    if (f == mover && released == null && last < 0) {
      if (inputOf(f) case final input? when mine.isEmpty) {
        steps.add(input);
        continue;
      }
      return (flows: all, steps: null);
    }
    final calls = {
      if (f == mover && last < 0) ?released,
      for (final w in mine.skip(last + 1))
        if (w case final PlatformCall c) c,
    };
    if (calls.isNotEmpty) {
      final within = [
        for (final s in ActivationStep.values)
          if (s.calls.containsAll(calls)) s,
      ];
      if (within.isEmpty) return (flows: all, steps: null);
      steps.addAll(within);
    } else if (last < 0) {
      final input = inputOf(f);
      if (input == null) return (flows: all, steps: null);
      steps.add(input);
    }
  }
  return (flows: all, steps: steps);
}

/// A choice point: its options in order, the default first (each a reply
/// or the next action's arrival), whether taking any but the first is free
/// (the flow that moved last could not go on), and how each is labelled. A
/// replay must meet the same options, not only as many.
typedef _Point = ({List<_Move> options, bool free, String labels});

/// What picks the option at each choice point of one run.
abstract interface class _Chooser {
  /// The option taken at the [at]th point, or null to stop the run there.
  int? choose({required int at, required _Point point});

  /// What the option taken at the [at]th point ran.
  void ran({required int at, required _Ran ran});
}

/// How a run ended: at the world's end state, broken, or stopped by its
/// chooser with nothing left to take.
sealed class _Outcome {
  const _Outcome();
}

final class _Reached extends _Outcome {
  const _Reached(this.state);

  final String state;
}

final class _Broke extends _Outcome {
  const _Broke(this.reason);

  final String reason;
}

final class _Stopped extends _Outcome {
  const _Stopped();
}

/// One point of the depth-first search: the point as the run met it, the
/// moves asleep there with what each ran where it was explored, the
/// preemptions spent before it, the option being explored, and those
/// explored, with what each ran.
final class _Node {
  _Node(this.point, {required this.sleep, required this.spent});

  final _Point point;
  final Map<_Move, _Ran> sleep;
  final int spent;
  int taken = 0;
  final Map<_Move, _Ran> done = {};

  int _cost(int option) => option > 0 && !point.free ? 1 : 0;

  int get spentAfter => spent + _cost(taken);

  /// The first option after [after] neither asleep, explored nor past
  /// [bound].
  int? next({required int bound, required int after}) {
    for (var i = after + 1; i < point.options.length; i++) {
      final move = point.options[i];
      if (sleep.containsKey(move) || done.containsKey(move)) continue;
      if (spent + _cost(i) > bound) continue;
      return i;
    }
    return null;
  }

  /// What sleeps in the options taken after the default: the default once
  /// explored, where taking it was no free choice.
  Map<_Move, _Ran> get keeps => switch (done[point.options.first]) {
    final ran? when !point.free => {point.options.first: ran},
    _ => const {},
  };
}

final class _Search implements _Chooser {
  _Search({required this.bound, required this.commutes});

  final int bound;
  final Commutes? commutes;
  final List<_Node> _path = [];
  Map<_Move, _Ran> _asleep = const {};

  /// Where a replay met other options, or saw a choice run other steps,
  /// than the run it replays, once one has.
  String? diverged;

  /// The preemptions the schedule on the path spends.
  int get spent => _path.isEmpty ? 0 : _path.last.spentAfter;

  @override
  int? choose({required int at, required _Point point}) {
    if (at < _path.length) {
      final node = _path[at];
      if (node.point.labels != point.labels || node.point.free != point.free) {
        diverged =
            'Replaying a schedule reached point $at as ${point.labels}, not '
            '${node.point.labels}';
        return null;
      }
      return node.taken;
    }
    final node = _Node(point, sleep: _asleep, spent: spent);
    final first = node.next(bound: bound, after: -1);
    if (first == null) return null;
    _path.add(node..taken = first);
    return first;
  }

  @override
  void ran({required int at, required _Ran ran}) {
    final node = _path[at];
    final move = node.point.options[node.taken];
    // The relation is read off what a choice ran, so a replay must run the
    // same, or a move would sleep on a footprint the run does not have.
    if (node.done[move] case final was? when !_same(was, other: ran)) {
      diverged =
          'Replaying a schedule ran ${ran.steps} in ${ran.flows} at point '
          '$at, not ${was.steps} in ${was.flows}';
    }
    node.done[move] ??= ran;
    if (at != _path.length - 1) return;
    final c = commutes;
    _asleep = c == null
        ? const {}
        : {
            for (final MapEntry(key: u, value: r) in {
              ...node.sleep,
              ...node.keeps,
            }.entries)
              if (u != move && _independent(r, other: ran, commutes: c)) u: r,
          };
  }

  /// Moves to the next schedule to run: false once none is left.
  bool advance() {
    while (_path.isNotEmpty) {
      final node = _path.last;
      if (node.next(bound: bound, after: node.taken) case final i?) {
        node.taken = i;
        return true;
      }
      _path.removeLast();
    }
    return false;
  }
}

Future<({List<String> trace, _Outcome outcome})> _runSchedule<A>({
  required ScheduledWorld<A> Function() world,
  required List<A> setup,
  required List<A> script,
  required _Chooser chooser,
}) {
  final result = Completer<({List<String> trace, _Outcome outcome})>();
  final trace = <String>[];
  final escaped = <Object>[];
  var restore = ActivationSteps.sink;
  // The throttled printer drains its buffer on a clock timer whose print
  // lands in the zone of whichever flow logged, at no chosen point.
  final printer = foundation.debugPrint;
  foundation.debugPrint = foundation.debugPrintSynchronously;
  void finish(_Outcome outcome) {
    _running = null;
    _log = null;
    stretchBegins = null;
    ActivationSteps.sink = restore;
    foundation.debugPrint = printer;
    if (!result.isCompleted) {
      result.complete((trace: trace, outcome: outcome));
    }
  }

  // Once the chooser stops the run, or it breaks, the rest of it takes the
  // default option at every point and nothing it meets counts: its flows
  // end as a schedule's do, so none waits on into the next run's world.
  _Outcome? ended;
  stretchBegins = (flow) {
    if (flow != null) _running?.add(flow);
  };
  unawaited(runZonedGuarded(() async {
    try {
      final w = world();
      final inner = restore = ActivationSteps.sink;
      ActivationSteps.sink =
          (step, {required outcome, required site, required tab}) {
            if (!onTheClock) _log?.add((flow: currentFlow(), what: step));
            inner?.call(step, outcome: outcome, site: site, tab: tab);
          };
      for (final action in setup) {
        await w.apply(action);
        await w.settle();
      }
      w.beginScript();
      w.gate._made.clear();
      final inputs = [for (final a in script) w.inputOf(a)];
      final begun = <int?>{};
      var next = 0;
      int? last;
      await quiesce(w);
      for (var at = 0;; at++) {
        if (ended == null && escaped.isNotEmpty) {
          ended = _Broke('${escaped.first}');
        }
        final pending = [...w.gate._pending];
        final own = [
          for (var i = 0; i < pending.length; i++)
            if (pending[i].move.flow == last) i,
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
        final chosen = ended == null
            ? chooser.choose(
                at: at,
                point: (
                  options: [
                    for (final o in options)
                      o == null ? (flow: next, nth: 0) : pending[o].move,
                  ],
                  free: free,
                  labels: [
                    for (final o in options)
                      o == null
                          ? '${script[next]}#$next'
                          : '${pending[o].call.label}#${pending[o].move.flow}',
                  ].join(', '),
                ),
              )
            : 0;
        if (chosen == null) ended = const _Stopped();
        final choice = chosen ?? 0;
        final mark = choice > 0 && !free ? '*' : '';
        final log = _log = <_Event>[];
        final ran = _running = <int?>{};
        final PlatformCall? released;
        if (options[choice] case final reply?) {
          final p = pending[reply];
          trace.add('$mark${p.call.label}#${p.move.flow}');
          last = p.move.flow;
          released = p.call;
          w.gate.release(reply);
        } else {
          final flow = next++;
          trace.add('$mark${script[flow]}#$flow');
          last = flow;
          released = null;
          w.start(script[flow]);
        }
        await quiesce(w);
        _running = null;
        _log = null;
        if (ended != null) continue;
        chooser.ran(
          at: at,
          ran: _ranOf(
            mover: last,
            flows: ran,
            released: released,
            log: log,
            begun: begun,
            inputs: inputs,
          ),
        );
        begun.addAll([
          for (final e in log)
            if (e.what is ActivationStep) e.flow,
        ]);
      }
      if (!w.idle) {
        return finish(
          ended ??
              const _Broke(
                'a flow never finished with no reply pending '
                '(a wait nothing can end)',
              ),
        );
      }
      await w.settle();
      await quiesce(w);
      if (ended case final outcome?) return finish(outcome);
      if (escaped.isEmpty) w.endScript();
      finish(
        escaped.isEmpty ? _Reached(w.snapshot()) : _Broke('${escaped.first}'),
      );
      // Known to throw: TestFailure (an Exception) from the world's
      // invariants, AssertionError from an owner's assert, and the Errors a
      // bug raises. Each fails the schedule, unless it ended before them.
      // ignore: webspace_lints/catch_all
    } on Exception catch (e) {
      finish(ended ?? _Broke(_reason(e)));
      // ignore: webspace_lints/catch_all
    } on Error catch (e) {
      finish(ended ?? _Broke(_reason(e)));
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
