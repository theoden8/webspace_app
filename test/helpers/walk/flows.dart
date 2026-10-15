import 'dart:async';

const _flowKey = #scheduleFlow;

/// Runs [body] as flow [flow]: every platform call its work makes, now or
/// after any await, belongs to that flow, and so does every change the
/// [segments] watcher sees across a stretch of its code that runs without
/// an await.
T inFlow<T>(T Function() body, {required int flow}) =>
    runZoned(body, zoneValues: {_flowKey: flow});

/// The flow the running code belongs to, or null outside any.
int? currentFlow() => Zone.current[_flowKey] as int?;

/// What a world reads of its state, and where it takes each flow's share
/// of the changes: [state] is compared before and after each stretch of
/// code that runs without an await, and what differs is [changed] to the
/// flow that stretch belongs to, or to null outside any. Code runs alone
/// between awaits, so a change there is the flow's own, whatever else is
/// in flight.
typedef SegmentWatch = ({
  Map<Object, String> Function() state,
  void Function(int? flow, {required Set<Object> keys, required bool closes})
  changed,
});

/// The watcher a world installs while it runs a script, or none.
SegmentWatch? segments;

/// The zone a runner runs a script in, so that every stretch of the
/// script's code, a flow's or not, opens a segment: a future completed in
/// one flow runs the next listener inline, in that listener's own zone, and
/// only a handler every zone of the script inherits sees it begin.
final ZoneSpecification segmentRuns = ZoneSpecification(
  run: <R>(Zone self, ZoneDelegate parent, Zone zone, ZoneCallback<R> f) =>
      _segment(zone, run: () => parent.run(zone, f)),
  runUnary:
      <R, A>(
        Zone self,
        ZoneDelegate parent,
        Zone zone,
        ZoneUnaryCallback<R, A> f,
        A a,
      ) => _segment(zone, run: () => parent.runUnary(zone, f, a)),
  runBinary:
      <R, A, B>(
        Zone self,
        ZoneDelegate parent,
        Zone zone,
        ZoneBinaryCallback<R, A, B> f,
        A a,
        B b,
      ) => _segment(zone, run: () => parent.runBinary(zone, f, a, b)),
);

/// The stretches running now, innermost last: a stretch whose code runs
/// another's inline takes back its share at the nested one's start and
/// starts afresh at its end.
final List<({int? flow, Map<Object, String> at})> _open = [];

R _segment<R>(Zone zone, {required R Function() run}) {
  final watch = segments;
  if (watch == null) return run();
  final now = watch.state();
  if (_open.isNotEmpty) _take(watch, now: now, closes: false);
  _open.add((flow: zone[_flowKey] as int?, at: now));
  try {
    return run();
  } finally {
    final end = watch.state();
    _take(watch, now: end, closes: true);
    _open.removeLast();
    if (_open.isNotEmpty) _open.last = (flow: _open.last.flow, at: end);
  }
}

/// The innermost stretch's changes so far, given to its flow: a step's
/// mark takes them before it checks what the step declares.
void takeSegment() {
  final watch = segments;
  if (watch == null || _open.isEmpty) return;
  _take(watch, now: watch.state(), closes: false);
}

/// Gives the innermost stretch's changes so far to its flow; [closes] when
/// the stretch ends there, so nothing more of it can follow.
void _take(
  SegmentWatch watch, {
  required Map<Object, String> now,
  required bool closes,
}) {
  final open = _open.last;
  final keys = {
    for (final k in {...open.at.keys, ...now.keys})
      if (open.at[k] != now[k]) k,
  };
  watch.changed(open.flow, keys: keys, closes: closes);
  _open.last = (flow: open.flow, at: now);
}
