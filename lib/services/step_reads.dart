part of 'step_table.dart';

/// The model's variables the step being landed has read so far: its
/// leaves, the ports it reaches and the operators it calls add to it as
/// they run. Null outside a landing.
Set<ModelVar>? _reading;

/// The action of the step being landed, which an input it spawns lands
/// in.
ActivationStep? _landing;

/// The action whose arm last took each flow to a place (by its fields):
/// what the call there reads as it is issued, before its first await, is
/// that action's, which prints what the call records ([Call.reads]). A
/// flow no step entered, started by hand, charges it to the call's own.
final _enteredBy = Expando<ActivationStep>('the action that entered');

/// [run] run with what it reads counted as [action]'s ([StepReads]).
T _charged<T>(
  ActivationStep action, {
  required T Function(Set<ModelVar> reading) run,
}) {
  final outer = _reading;
  final reading = _reading = <ModelVar>{};
  try {
    return run(reading);
  } finally {
    _reading = outer;
    assert(() {
      (StepReads._read[action] ??= {}).addAll(reading);
      return true;
    }());
  }
}

/// [f] run without its reads counted as the landing step's: a check the
/// runner makes of the step, which is no read of the step's.
T _unread<T>(T Function() f) {
  final outer = _reading;
  _reading = null;
  try {
    return f();
  } finally {
    _reading = outer;
  }
}

/// What each step read of the shared state as it landed, by the action
/// the model takes it in (a spawned input's, its spawner's), in debug
/// builds: the walks hold it to the printed footprints, which the
/// schedules' reduction and the footprint gate take as what each reads.
abstract final class StepReads {
  static final _read = <ActivationStep, Set<ModelVar>>{};

  static Map<ActivationStep, Set<ModelVar>> get read => Map.unmodifiable(_read);

  @visibleForTesting
  static void forget() => _read.clear();
}

void _noteReads(Reads r) {
  final into = _reading;
  if (into == null) return;
  into.addAll(r.vars);
  for (final b in r.base) {
    into.addAll(b.reads);
  }
}
