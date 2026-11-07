part of 'step_table.dart';

/// A lock whose turn a step waits on: a platform object whose operations a
/// queue serialises, one flow holding it at a time. The model has one
/// definition of a turn (`formal/activation_lock.tla`) and one instance of
/// it a lock, over the lock's own [holder] and [queue] ([instance]); a step
/// waits on the turn as [granted] and takes, passes and lets go of it
/// through the acts here.
enum Lock {
  /// The shared cookie jar (`CookieIsolationEngine._turns`, ISO-003).
  jar(holder: ModelVar.holder, queue: ModelVar.queue, witness: 'queued');

  const Lock({
    required this.holder,
    required this.queue,
    required this.witness,
  });

  /// The flow holding the turn, 0 for none.
  final ModelVar holder;

  /// The flows waiting for it, in order.
  final ModelVar queue;

  /// What a flow queued behind a holder adds to `seen`.
  final String witness;

  /// Its instance's name in the model: the enum's, capitalised.
  String get tla => '${name[0].toUpperCase()}${name.substring(1)}';

  /// The instance of `activation_lock` the model's steps call through.
  String get instance =>
      '$tla == INSTANCE activation_lock WITH holder <- ${holder.name}, '
      'queue <- ${queue.name}, Witness <- "$witness"';

  /// The model's guard for a flow `f` whose turn on the lock it is.
  String get granted => '$tla!Granted(f)';

  /// What the guard reads of the shared state.
  Reads get grantedReads => Reads(vars: {holder, queue});

  /// The flow joins the queue.
  Act<W> enqueue<W>() => modelOnly(
    '$tla!Enqueue(f)',
    writes: {queue, ModelVar.seen},
    reads: Reads(vars: {holder, queue}),
  );

  /// The granted flow holds the turn.
  Act<W> takeTurn<W>() => modelOnly(
    '$tla!TakeTurn(f)',
    writes: {holder, queue},
    reads: Reads(vars: {queue}),
  );

  /// The granted flow passes the turn on at once.
  Act<W> passTurn<W>() => modelOnly(
    '$tla!PassTurn',
    writes: {holder, queue},
    reads: Reads(vars: {queue}),
  );

  /// The holder lets the turn go.
  Act<W> release<W>() =>
      modelOnly('$tla!Release', writes: {holder}, reads: Reads.none);

  /// Each operator of its instance with what it reads and writes of the
  /// shared state, the checkers' own (`seen`) apart, which footprint.py
  /// holds to the text (`activation_base_ops.tsv`).
  List<({String op, Set<ModelVar> reads, Set<ModelVar> writes})> get ops => [
    (op: '$tla!Granted', reads: grantedReads.vars, writes: const {}),
    for (final a in <Act<Object?>>[
      enqueue(),
      takeTurn(),
      passTurn(),
      release(),
    ])
      (
        op: a.tla.split('(').first,
        reads: a.reads.vars,
        writes: {...a.writes}..remove(ModelVar.seen),
      ),
  ];
}
