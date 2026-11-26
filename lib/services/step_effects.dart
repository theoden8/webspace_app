part of 'step_table.dart';

/// What a branch does, and what that is in the model: to the flow's
/// fields, to the model's shared variables, or to the code alone.
sealed class Effect<W> {
  const Effect({required this.run});

  final void Function(StepView<W> c) run;
}

/// What a step does to the model's shared variables: its [writes], taken
/// by the engine's state through their variables ([Act.of]), or an
/// operator of the model's own named by its [tla] (`Dispose(f)`), beside
/// what the code does for it.
final class Act<W> extends Effect<W> {
  const Act({
    required this.writes,
    required this.tla,
    required this.reads,
    required super.run,
  });

  /// `name' = <to>` for each of [writes], every value read over the state
  /// the step found, as the model's primed writes are, and then put in in
  /// order; then what the code does once they are in ([then]): its half of
  /// a write the platform holds, an assert over the new state, a notify, a
  /// log.
  Act.of(List<Write<W>> writes, {void Function(CommitView<W> c)? then})
    : writes = {for (final w in writes) w.variable},
      tla = [for (final w in writes) w.tla].join(' /\\ '),
      reads = Reads.of([for (final w in writes) w.reads]),
      super(
        run: (c) {
          final staged = [for (final w in writes) w.stage(c)];
          for (final put in staged) {
            put();
          }
          then?.call(CommitView._(c));
        },
      );

  final Set<ModelVar> writes;
  final String tla;
  final Reads reads;
}

/// `![f].<field> = <to>` in the model; made by [Field.becomes].
final class Assign<W> extends Effect<W> {
  const Assign._({
    required this.field,
    required this.to,
    required this.reads,
    required super.run,
  });

  final FlowField field;
  final String to;
  final Reads reads;
}

/// What only the code does: a log line, an in-memory copy the model does
/// not name. It prints nothing, so it is where the code could do what the
/// model does not see: keep it to state no invariant reads. What it reads
/// of the model's state is [reads]: the code's alone, so it is no part of
/// the step's printed footprint, and the walks hold the note to it.
final class Note<W> extends Effect<W> {
  const Note(void Function(StepView<W> c) run, {this.reads = Reads.none})
    : super(run: run);

  final Reads reads;
}

/// Another table's input this step starts in its own turn, as the code
/// does it ([start]: the call that runs [input]'s step before any await),
/// on [site], the element the input's pick takes, where [when] holds. The
/// runner starts it after the arm's other effects and its mark, and asserts
/// that [input]'s step landed there, once; the model prints the input's
/// effects in this step's action, on the flow numbered next (`Starts`),
/// over the state the arm's other effects leave. An input that lands in a
/// step's turn any other way is asserted against, so the code starts no
/// flow the model does not print.
final class Spawn<W> extends Effect<W> {
  Spawn(
    this.input, {
    required this.site,
    required this.when,
    required void Function(StepView<W> c) start,
  }) : super(
         run: (c) {
           final turn = _turn!;
           if (!when.run(c)) return;
           turn.spawning = input;
           try {
             start(c);
           } finally {
             turn.spawning = null;
           }
           assert(
             turn.started,
             '${turn.step} spawns $input where ${when.tla}, and its code '
             'started none',
           );
         },
       );

  final ActivationStep input;
  final Expr<Object?, W> site;
  final Expr<bool, W> when;
}

/// The step whose arm runs now, the input its [Spawn] is starting, and the
/// inputs that landed in its turn otherwise.
final class _Turn {
  _Turn(this.step);

  final ActivationStep step;
  ActivationStep? spawning;
  bool started = false;
  final List<ActivationStep> strays = [];

  /// Asserted by the step's own flow, which a throw from the input's flow
  /// would not reach.
  bool get keptToSpawns {
    assert(
      strays.isEmpty,
      '$strays landed in the turn of $step, which spawns no such input',
    );
    return true;
  }
}

_Turn? _turn;

/// [input]'s step lands: outside any step's turn, or as the one input the
/// spawn that turn runs starts, the only place a [Step.spawned] lands.
void _admit(ActivationStep input, {required bool spawned}) {
  final turn = _turn;
  assert(
    !spawned || turn?.spawning == input,
    '$input is started only by its Spawn, in the turn of the step that spawns it',
  );
  if (turn == null) return;
  if (turn.spawning == input && !turn.started) {
    turn.started = true;
  } else {
    turn.strays.add(input);
  }
}
