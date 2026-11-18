part of 'step_table.dart';

/// A lock whose turn a step waits on: a platform object whose operations a
/// queue serialises, one flow holding it at a time. The model has one
/// definition of a turn (`formal/activation_lock.tla`) and one instance of
/// it a lock, over the lock's own [holder] and [queue] ([instance]); a step
/// waits on the turn as [granted] and takes, passes and lets go of it
/// through the acts here.
enum Lock {
  /// The shared cookie jar (`CookieIsolationEngine._turns`, ISO-003).
  jar(holder: ModelVar.holder, queue: ModelVar.queue, witness: 'queued'),

  /// The DNS lists (`DnsBlockService._mutations`, DNS-019, DNS-021,
  /// DNS-022).
  dns(
    holder: ModelVar.dnsHolder,
    queue: ModelVar.dnsQueue,
    witness: 'dnsQueued',
  );

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
  String get granted => grantedTo(flow: 'f');

  /// The model's guard for [flow] whose turn on the lock it is: `f`, or
  /// `0` for the environment's ([LaunchTurn]).
  String grantedTo({required String flow}) => '$tla!Granted($flow)';

  /// What the guard reads of the shared state.
  Reads get grantedReads => Reads(vars: {holder, queue});

  /// The flow joins the queue. Each act's [run] is what the code does for
  /// it where the code keeps the turn's state itself; where the queue's own
  /// structure keeps it, nothing.
  Act<W> enqueue<W>({void Function(StepView<W> c)? run}) => Act(
    writes: {queue, ModelVar.seen},
    tla: '$tla!Enqueue(f)',
    reads: Reads(vars: {holder, queue}),
    run: run ?? (_) {},
  );

  /// The granted flow holds the turn.
  Act<W> takeTurn<W>({void Function(StepView<W> c)? run}) => Act(
    writes: {holder, queue},
    tla: '$tla!TakeTurn(f)',
    reads: Reads(vars: {queue}),
    run: run ?? (_) {},
  );

  /// The granted flow passes the turn on at once.
  Act<W> passTurn<W>({void Function(StepView<W> c)? run}) => Act(
    writes: {holder, queue},
    tla: '$tla!PassTurn',
    reads: Reads(vars: {queue}),
    run: run ?? (_) {},
  );

  /// The holder lets the turn go.
  Act<W> release<W>({void Function(StepView<W> c)? run}) => Act(
    writes: {holder},
    tla: '$tla!Release',
    reads: Reads.none,
    run: run ?? (_) {},
  );

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

/// A lock's turn where the code keeps it itself beside the queue that
/// serialises the lock's operations: the flow holding it and the flows
/// waiting, as variables of the table whose steps take turns, so the frame
/// check holds every other step to leaving them alone. Its acts do in the
/// code what the model's instance of `activation_lock` does, and assert
/// that the queue serves the turns in the order they were asked.
final class Turns<W> {
  const Turns(this.lock, {required this.holder, required this.queue});

  final Lock lock;
  final Mutable<StepView<W>?, W> holder;
  final Mutable<List<StepView<W>>, W> queue;

  /// Past the step that grants it, a flow holds the turn.
  Expr<bool, W> get held => holder.value.eq(
    Expr<StepView<W>?, W>._(run: (c) => c, tla: 'f', reads: Reads.none),
  );

  Act<W> get enqueue => lock.enqueue(
    run: (c) => queue._write!(c._world, to: [...queue._read!(c._world), c]),
  );

  Act<W> get takeTurn => lock.takeTurn(
    run: (c) {
      _granted(c);
      queue._write!(c._world, to: queue._read!(c._world).sublist(1));
      holder._write!(c._world, to: c);
    },
  );

  Act<W> get passTurn => lock.passTurn(
    run: (c) {
      _granted(c);
      queue._write!(c._world, to: queue._read!(c._world).sublist(1));
    },
  );

  Act<W> get release => lock.release(
    run: (c) {
      assert(
        identical(holder._read!(c._world), c),
        "a flow let go of ${lock.name}'s turn it does not hold",
      );
      holder._write!(c._world, to: null);
    },
  );

  void _granted(StepView<W> c) {
    final waiting = queue._read!(c._world);
    assert(
      holder._read!(c._world) == null &&
          waiting.isNotEmpty &&
          identical(waiting.first, c),
      "${lock.name}'s turn went to a flow out of the order asked",
    );
  }
}

/// The environment's turn on a lock where the code queues it at launch,
/// before any input: the model's flow 0, in the lock's queue from `Init`
/// (`Launched_<Lock>`, printed for a lock an environment step is granted
/// on). Whether it still waits is kept by the code beside the queue that
/// serialises the lock, so the frame check holds the step the turn grants
/// to the pass it declares.
final class LaunchTurn<W> {
  const LaunchTurn(this.lock, {required this.waiting});

  final Lock lock;
  final Mutable<bool, W> waiting;

  /// The environment passes the turn on at once (`PassTurn`): it waits no
  /// more.
  Act<W> get passTurn => lock.passTurn(
    run: (c) {
      assert(
        waiting._read!(c._world),
        "${lock.name}'s launch turn passed on where none was queued",
      );
      waiting._write!(c._world, to: false);
    },
  );
}
