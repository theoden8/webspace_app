import 'dart:async';

import 'package:meta/meta.dart' show visibleForTesting;
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/hand_paired.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/site_tab.dart';

export 'package:webspace/services/hand_paired.dart';
export 'package:webspace/services/model_names.dart';
export 'package:webspace/services/step_print.dart';

part 'model_exprs.dart';
part 'step_reads.dart';

/// What a table's own code sees of one flow: the values its steps keep,
/// the element a step picked, the names a quantifier bound. Not the
/// engine's world: a step reaches that only through the leaves and ports
/// its table declares, so an undeclared read or write does not compile.
base class StepView<W> {
  StepView._({
    required W world,
    required Map<Field<Object?, Object?>, Object?> fields,
    required Map<String, Object?> bound,
    required Map<String, Object?> picked,
  }) : _world = world,
       _fields = fields,
       _bound = bound,
       _picked = picked;

  final W _world;
  final Map<Field<Object?, Object?>, Object?> _fields;
  final Map<String, Object?> _bound;
  final Map<String, Object?> _picked;
}

/// The view a call made on a port sees ([Call.on]): the flow's fields, and
/// the port's interface as [api].
final class PortView<I, W> extends StepView<W> {
  PortView._(StepView<W> view, {required this.api})
    : super._(
        world: view._world,
        fields: view._fields,
        bound: view._bound,
        picked: view._picked,
      );

  final I api;
}

/// The view the code half of a write sees ([Act.of]'s and [Call.on]'s
/// `then`): the flow's fields, and the turn's [commit], so a variable the
/// code holds for the model ([SharedAt], `WebViewTabBinding.queue`) is
/// written there and nowhere else.
final class CommitView<W> extends StepView<W> {
  CommitView._(StepView<W> view)
    : commit = const Commit._(),
      super._(
        world: view._world,
        fields: view._fields,
        bound: view._bound,
        picked: view._picked,
      );

  final Commit commit;
}

/// One flow through a table, as the engine that runs it holds it: the view
/// its steps see, and the engine's [world].
final class StepContext<W> extends StepView<W> {
  StepContext(W world) : super._(world: world, fields: {}, bound: {}, picked: {});

  /// A view of [other]'s flow for a table nested in it ([Within]): the same
  /// fields, read through another world.
  StepContext.sharing(StepView<Object?> other, {required W world})
    : super._(world: world, fields: other._fields, bound: {}, picked: {});

  W get world => _world;
}

/// [value] as TLA+ prints a constant: a number, a string, a boolean or a
/// set of those.
String tlaOf(Object? value) => switch (value) {
  bool b => b ? 'TRUE' : 'FALSE',
  int n => '$n',
  String t => '"$t"',
  Enum e => '"${e.name}"',
  Iterable<Object?> i => '{${i.map(tlaOf).join(', ')}}',
  _ => throw ArgumentError.value(value, 'value', 'has no TLA+ form'),
};

/// A value of a step in both its readings, derived from one tree: what it
/// is when the code runs ([run]) and its TLA+ text ([tla]), with the flow
/// as `f` and a picked element as `s`. The leaves are the model's variables
/// ([Var], [Indexed], [Members], [Field]), constants, and the model's
/// operators ([Expr.op]); the operators below build the rest, so a guard
/// is written once and read both ways.
final class Expr<T, W> {
  const Expr._({
    required this.run,
    required this.tla,
    required this.reads,
    this.needs = const {},
    this.unless = const {},
    this.literal,
    this.kinds,
    this.exactKinds = false,
    List<({Set<Need> needs, String tla})>? cases,
  }) : _cases = cases;

  final T Function(StepView<W> c) run;
  final String tla;
  final Reads reads;

  /// What the model's constants must be for this to hold, or for a set to
  /// have members: the leaves that read a constant say, and the operators
  /// carry it (`/\` unions, `\/` intersects); a value that says nothing
  /// needs nothing, which is never wrong.
  final Set<Need> needs;

  /// What the model's constants must be for this not to hold: `~` swaps it
  /// with [needs], and an arm after a branch that did not hold needs it.
  final Set<Need> unless;

  /// The constant this is, read at one site: what `#` reads a need off.
  final ModelConst? literal;

  final List<({Set<Need> needs, String tla})>? _cases;

  /// The values this can take, each with what it needs to be the one: an
  /// `IF` takes its branches, under its condition and its failing.
  List<({Set<Need> needs, String tla})> get cases =>
      _cases ?? [(needs: const {}, tla: tla)];

  /// The kinds of flow whose row this can hold for, null for any: a test
  /// of the flow's own kind ([KindField.isKind]) holds for its kinds only,
  /// and for exactly those when [exactKinds].
  final Set<FlowKind>? kinds;
  final bool exactKinds;

  /// A constant, printed from its value ([tlaOf]) unless [tla] says how.
  static Expr<V, W> constant<V, W>(V value, {String? tla}) =>
      Expr._(run: (_) => value, tla: tla ?? tlaOf(value), reads: Reads.none);

  /// The empty set.
  static Expr<List<E>, W> none<E, W>() =>
      Expr._(run: (_) => <E>[], tla: '{}', reads: Reads.none);

  /// The flow itself, `f`.
  static Expr<Object?, W> flow<W>() =>
      Expr._(run: (c) => c, tla: 'f', reads: Reads.none);

  /// An operator of the model's own ([tla], defined in `activation_base`),
  /// beside the engine's rule for it, and what its text reads; [pairing]
  /// names the pair ([HandPaired]).
  static Expr<V, W> op<V, W>(
    Pairing pairing, {
    required String tla,
    required V Function(StepView<W> c) run,
    required Reads reads,
    Set<Need> needs = const {},
  }) => Expr._(
    run: (c) {
      _noteReads(reads);
      return run(c);
    },
    tla: tla,
    reads: reads,
    needs: needs,
  );

  /// Text of the model's beside code of the engine's, written side by side
  /// over what [reads] names: nothing but the replay holds the two to each
  /// other, so each use is a pair still to close into a tree, which
  /// [pairing] names ([HandPaired]).
  static Expr<V, W> handPaired<V, W>(
    Pairing pairing, {
    required String tla,
    required V Function(StepView<W> c) run,
    required Reads reads,
    Set<Need> needs = const {},
  }) => Expr._(run: run, tla: tla, reads: reads, needs: needs);

  /// What the engine computes for a set the model states by [rule]: the
  /// engine's value runs, asserted the same set as [rule]'s by [key] (the
  /// model's name for an element the engine holds), which is what prints.
  /// [why] names the rule for the assert.
  static Expr<List<E>, W> checked<E, K, W>({
    required Expr<Iterable<K>, W> rule,
    required Iterable<E> Function(StepView<W> c) run,
    required K Function(E e) key,
    required String why,
  }) => Expr._(
    run: (c) {
      final engine = run(c).toList();
      assert(() {
        final printed = rule.run(c).toSet();
        final ran = {for (final e in engine) key(e)};
        return printed.length == ran.length && printed.containsAll(ran);
      }(), why);
      return engine;
    },
    tla: rule.tla,
    reads: rule.reads,
  );

  /// The engine's choice where the model chooses ([among], a [Pick]'s
  /// element or set): the replay holds the engine to a choice the model
  /// allows.
  static Expr<V, W> chosen<V, W>({
    required Expr<V, W> among,
    required V Function(StepView<W> c) run,
  }) => Expr._(run: run, tla: among.tla, reads: among.reads);

  /// The model's constant [of], as the code knows it through what [run]
  /// reads: printed by its name, needing what reading it whole needs.
  static Expr<V, W> ofConstant<V, W>(
    ModelConst of, {
    required V Function(StepView<W> c) run,
  }) => Expr._(
    run: run,
    tla: of.tla,
    reads: Reads.none,
    needs: _needs(of),
    unless: _unless(of),
    literal: of,
  );

  /// Whether a flow of [kind] is in flight, the model's
  /// `"<kind>" \in Kinds`: the kind of every other row of [kind], which
  /// only an input of [kind] and the end of such a flow write.
  static Expr<bool, W> inFlight<W>(
    FlowKind kind, {
    required bool Function(StepView<W> c) run,
  }) => Expr._(
    run: run,
    tla: '"${kind.name}" \\in Kinds',
    reads: Reads(
      base: const {BaseOp.kinds},
      rows: {(kind: kind, field: FlowField.kind)},
    ),
  );

  static Expr<V, W> choose<V, W>({
    required Expr<bool, W> when,
    required Expr<V, W> then,
    required Expr<V, W> otherwise,
  }) => Expr._(
    run: (c) => when.run(c) ? then.run(c) : otherwise.run(c),
    tla: 'IF ${when.tla} THEN ${then.tla} ELSE ${otherwise.tla}',
    reads: when.reads + then.reads + otherwise.reads,
    needs: then.needs.intersection(otherwise.needs),
    unless: then.unless.intersection(otherwise.unless),
    cases: [
      for (final c in then.cases)
        (needs: {...c.needs, ...when.needs}, tla: c.tla),
      for (final c in otherwise.cases)
        (needs: {...c.needs, ...when.unless}, tla: c.tla),
    ],
  );

  Expr<bool, W> eq(Expr<T, W> other) => Expr._(
    run: (c) => run(c) == other.run(c),
    tla: '${tlaOperand(tla)} = ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
    unless: _differs(other),
  );

  Expr<bool, W> neq(Expr<T, W> other) => Expr._(
    run: (c) => run(c) != other.run(c),
    tla: '${tlaOperand(tla)} # ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
    needs: _differs(other),
  );

  /// Two reads of one function constant differ only where a world makes
  /// it differ between sites.
  Set<Need> _differs(Expr<T, W> other) => {
    if (literal case final k?
        when k == other.literal && k.kind == ConstKind.uniform)
      (of: k, set: true),
  };
}

/// A variable a quantifier or a set builder binds (`\A t \in S`,
/// `{x \in S : ...}`) or a definition takes: [it] reads what it is bound to
/// while the body runs.
final class Bound<E, W> {
  const Bound(this.name);

  final String name;

  Expr<E, W> get it =>
      Expr._(run: (c) => c._bound[name] as E, tla: name, reads: Reads.none);

  R _with<R>(
    StepView<W> c, {
    required E value,
    required R Function() body,
  }) {
    final had = c._bound.containsKey(name);
    final prior = c._bound[name];
    c._bound[name] = value;
    try {
      return body();
    } finally {
      if (had) {
        c._bound[name] = prior;
      } else {
        c._bound.remove(name);
      }
    }
  }
}

/// An operator of the model defined by the engine that owns the variables
/// its [body] reads, so its rule runs in that engine and prints as
/// A definition called where its owner is out of reach: by its name alone,
/// run as the code's own check of it ([run]).
extension DefCall on ModelDef {
  /// `Name(f)`, the definition over the flow.
  Expr<T, W> ofFlow<T, W>({required T Function(StepView<W> c) run}) =>
      Expr._(run: run, tla: '$tla(f)', reads: Reads(defs: {this}));

  /// `Name`, a definition with no parameters.
  Expr<T, W> named<T, W>({required T Function(StepView<W> c) run}) =>
      Expr._(run: run, tla: tla, reads: Reads(defs: {this}));

  /// `Name(args)`.
  Expr<T, W> over<T, W>(
    List<Expr<Object?, W>> args, {
    required T Function(StepView<W> c) run,
  }) => Expr._(
    run: run,
    tla: '$tla(${[for (final a in args) a.tla].join(', ')})',
    reads: Reads(defs: {this}) + Reads.of([for (final a in args) a.reads]),
  );
}

/// `Name(params) == body` (`activation_ops`); elsewhere it is called by name
/// ([Expr.op]). A definition over the flow, `Name(f)`, reads the flow's
/// fields; one over [params] binds them to its arguments.
final class Def<T, W> {
  const Def(this.id, {this.params = const [], required this.body})
    : overFlow = false;

  const Def.ofFlow(this.id, {required this.body})
    : params = const [],
      overFlow = true;

  final ModelDef id;
  String get name => id.tla;
  final List<Bound<Object?, W>> params;
  final bool overFlow;
  final Expr<T, W> body;

  String get tla {
    final header = overFlow
        ? '(f)'
        : params.isEmpty
        ? ''
        : '(${[for (final p in params) p.name].join(', ')})';
    return '$name$header == ${body.tla}';
  }

  /// The definition applied to [args], one per parameter: the model's call
  /// `Name(args)`, run as the body over the arguments' values.
  Expr<T, W> call(List<Expr<Object?, W>> args) {
    assert(args.length == params.length, '$name takes ${params.length}');
    return Expr._(
      run: (c) {
        final values = [for (final a in args) a.run(c)];
        if (Planted._current?.defs[id] case final planted?) {
          return planted._apply(c, values: values) as T;
        }
        return _bind(c, values: values);
      },
      tla: overFlow
          ? '$name(f)'
          : args.isEmpty
          ? name
          : '$name(${[for (final a in args) a.tla].join(', ')})',
      reads: body.reads + Reads.of([for (final a in args) a.reads]),
      needs: body.needs,
      unless: body.unless,
    );
  }

  /// A definition with no parameters, or over the flow, as a value.
  Expr<T, W> get value => call(const []);

  /// The definition over [args] in [world], for code outside a table that
  /// asks the model's rule of values in hand.
  T evaluate(W world, {required List<Object?> args}) {
    assert(args.length == params.length, '$name takes ${params.length}');
    final c = StepContext(world);
    if (Planted._current?.defs[id] case final planted?) {
      return planted._apply(c, values: args) as T;
    }
    return _bind(c, values: args);
  }

  T _bind(StepView<W> c, {required List<Object?> values}) {
    T bind(int i) => i == params.length
        ? body.run(c)
        : params[i]._with(c, value: values[i], body: () => bind(i + 1));
    return bind(0);
  }

  /// The body over [values], run on [c] as a view of this definition's own
  /// world, for a planted definition standing in for the code's.
  Object? _apply(StepView<Object?> c, {required List<Object?> values}) {
    assert(values.length == params.length, '$name takes ${params.length}');
    return switch (c) {
      final StepView<W> view => _bind(view, values: values),
      _ => throw StateError('$name is planted over another world'),
    };
  }
}

/// What a set the model quantifies over binds: each operator here binds
/// a [Bound] while its body runs.
extension QuantifiedExpr<E, W> on Expr<Iterable<E>, W> {
  /// `S \ T`, [other] known by membership.
  Expr<List<E>, W> minus(Members<E, W> other) => Expr._(
    run: (c) => [
      for (final e in run(c))
        if (!other._test(c._world, member: e)) e,
    ],
    tla: '${tlaOperand(tla)} \\ ${other.name}',
    reads: reads,
    needs: needs,
  );

  /// `[x \in S |-> to]`: a function of the model over S, run as a map.
  Expr<Map<E, V>, W> mapTo<V>(Bound<E, W> x, {required Expr<V, W> to}) => Expr._(
    run: (c) => {
      for (final e in run(c)) e: x._with(c, value: e, body: () => to.run(c)),
    },
    tla: '[${x.name} \\in ${tlaOperand(tla)} |-> ${to.tla}]',
    reads: reads + to.reads,
  );

  /// `\A x \in S : holds`.
  Expr<bool, W> forAll(Bound<E, W> x, {required Expr<bool, W> holds}) => Expr._(
    run: (c) =>
        run(c).every((e) => x._with(c, value: e, body: () => holds.run(c))),
    tla: '\\A ${x.name} \\in ${tlaOperand(tla)} : ${holds.tla}',
    reads: reads + holds.reads,
    unless: {...needs, ...holds.unless},
  );

  /// `\E x \in S : holds`.
  Expr<bool, W> exists(Bound<E, W> x, {required Expr<bool, W> holds}) => Expr._(
    run: (c) =>
        run(c).any((e) => x._with(c, value: e, body: () => holds.run(c))),
    tla: '\\E ${x.name} \\in ${tlaOperand(tla)} : ${holds.tla}',
    reads: reads + holds.reads,
    needs: {...needs, ...holds.needs},
  );

  /// `{x \in S : holds}`, in the order of S.
  Expr<List<E>, W> where(Bound<E, W> x, {required Expr<bool, W> holds}) =>
      Expr._(
        run: (c) => [
          for (final e in run(c))
            if (x._with(c, value: e, body: () => holds.run(c))) e,
        ],
        tla: '{${x.name} \\in ${tlaOperand(tla)} : ${holds.tla}}',
        reads: reads + holds.reads,
        needs: {...needs, ...holds.needs},
      );
}

/// A value the code holds as nullable where the model has it set.
extension UnwrappedExpr<T extends Object, W> on Expr<T?, W> {
  /// The same text, run as the value itself.
  Expr<T, W> get unwrapped =>
      Expr._(run: (c) => run(c)!, tla: tla, reads: reads);
}

/// A variable of the model as the engine reads it: its name is its TLA+
/// text, [read] what it is in the engine's state, fresh (a collection is
/// copied), so two reads compare as values.
class Var<T, W> {
  const Var(this.variable, {required T Function(W world) read})
    : _read = read;

  const Var._remote(this.variable) : _read = null;

  final ModelVar variable;
  String get name => variable.name;
  final T Function(W world)? _read;

  Expr<T, W> get value => Expr._(
    run: (c) {
      _reading?.add(variable);
      return switch (_read) {
        final read? => read(c._world),
        null => throw StateError('$name is read only through a call'),
      };
    },
    tla: name,
    reads: Reads(vars: {variable}),
  );
}

/// A constant of the model (`Containers`), read from the world the table
/// runs against and printed by its name: a switch needs its setting to
/// hold, a set needs a world that fills it to have members.
final class Constant<T, W> {
  const Constant(this.of, {required T Function(W world) read}) : _read = read;

  final ModelConst of;
  String get name => of.tla;
  final T Function(W world) _read;

  Expr<T, W> get value => Expr._(
    run: (c) => _read(c._world),
    tla: name,
    reads: Reads.none,
    needs: _needs(of),
    unless: _unless(of),
    literal: of,
  );
}

/// What reading [c] whole needs: a switch its setting off the base's, a
/// set a world's members.
Set<Need> _needs(ModelConst c) => switch (c.kind) {
  ConstKind.off || ConstKind.set => {(of: c, set: true)},
  ConstKind.on => {(of: c, set: false)},
  ConstKind.uniform || ConstKind.bound || ConstKind.fixed => const {},
};

/// What a switch [c] needs to be off: the other setting.
Set<Need> _unless(ModelConst c) => switch (c.kind) {
  ConstKind.off => {(of: c, set: false)},
  ConstKind.on => {(of: c, set: true)},
  ConstKind.set ||
  ConstKind.uniform ||
  ConstKind.bound ||
  ConstKind.fixed => const {},
};

/// A variable a step of the engine writes: [write] is how the engine's
/// state takes the new value, which the table runner applies for an act's
/// declared writes ([Act.of]). One the platform holds, which the code
/// reaches only through a call, is [Mutable.remote]: the call itself is
/// the write.
final class Mutable<T, W> extends Var<T, W> {
  const Mutable(
    super.name, {
    required super.read,
    required void Function(W world, {required T to}) write,
  }) : _write = write;

  const Mutable.remote(super.name) : _write = null, super._remote();

  /// The view a table takes of a [Shared] variable it reaches through its
  /// world, under the name the owner gave it.
  factory Mutable.over(
    ModelVar variable, {
    required Shared<T> Function(W world) of,
  }) => Mutable(
    variable,
    read: (w) {
      final cell = of(w);
      assert(cell.variable == variable, '${cell.name} is not ${variable.name}');
      assert(cell._takes<T>(), cell._narrower(than: T));
      return cell._read();
    },
    write: (w, {required to}) {
      final cell = of(w);
      assert(cell._takes<T>(), cell._narrower(than: T));
      cell._write(to);
    },
  );

  final void Function(W world, {required T to})? _write;

  /// `name' = <to>`.
  Write<W> becomes(Expr<T, W> to) => Write._(
    variable,
    to: to.tla,
    reads: to.reads,
    stage: (c) {
      final write = _write;
      if (write == null) return () {};
      final value = to.run(c);
      return () => write(c._world, to: value);
    },
  );
}

/// A variable of the model as the state that owns it keeps it, with no
/// flow in hand: the owner declares it once and reads it anywhere, and it
/// is written only through a table's [Write] ([Mutable.over]) or by the
/// owner's own methods that are the environment's actions, so a write
/// outside a table's arm has no handle to write with.
final class Shared<T> {
  Shared(
    this.variable, {
    required T Function() read,
    required void Function(T to) write,
  }) : _read = read,
       _write = write;

  /// A set of the code's as the model's [variable], for a test or a host
  /// that keeps it as a set.
  static Shared<Iterable<E>> ofSet<E>(
    Set<E> set, {
    required ModelVar variable,
  }) => Shared(
    variable,
    read: () => set.toSet(),
    write: (to) => set
      ..clear()
      ..addAll(to),
  );

  final ModelVar variable;
  String get name => variable.name;
  final T Function() _read;
  final void Function(T to) _write;

  T get value => _read();

  /// Whether a view of this cell as a `Shared<U>` can write what it reads:
  /// `U` is no wider than the type the cell was made with. Dart's generics
  /// are covariant, so a cell inferred as `Shared<Set<X>>` stands where a
  /// `Shared<Iterable<X>>` is asked for, and every write through it throws.
  bool _takes<U>() => <U>[] is List<T>;

  String _narrower({required Type than}) =>
      '$name was made as Shared<$T> but is written as Shared<$than>; give '
      'the cell, or the engine reaching it, its type arguments';
}

/// A turn in which the model's state may be written: the runner makes one
/// for each arm it applies, [commitInput] for an input the code marks by
/// hand, and [Commit.unmodeled] for a write no step of the model takes yet,
/// which names why. A cell the code shares ([SharedAt]) writes only with
/// one in hand, so a write outside them does not compile.
final class Commit {
  const Commit._() : unmodeled = null, environment = null;

  /// A write no step of the model takes yet: debt, which a step that takes
  /// it retires.
  const Commit.unmodeled(Unmodeled this.unmodeled) : environment = null;

  /// A write of one of the environment's actions `activation.tla` states by
  /// hand: the model takes it there, not in a table's step.
  const Commit.environment(Environment this.environment) : unmodeled = null;

  /// A model a test builds before any step runs.
  @visibleForTesting
  const Commit.fixture() : unmodeled = null, environment = null;

  final Unmodeled? unmodeled;
  final Environment? environment;

  /// This commit wrote [variable]. A write no step takes is stamped, so a
  /// step that reads the variable once its flow's await is over learns it
  /// met one ([UnmodeledWrites]).
  void wrote(ModelVar variable) {
    if (unmodeled case final by?) {
      UnmodeledWrites._last[variable] = (at: ++UnmodeledWrites._now, by: by);
    }
  }
}

/// The writes of the model's variables no step takes ([Commit.unmodeled]),
/// stamped as they happen, and each step that met one: a step that read,
/// after its flow's await, a variable such a write changed during it. That
/// step decides on a state the model never has there, so its timing is
/// outside what TLC checked; the walks hold [met] to the list they owe.
abstract final class UnmodeledWrites {
  static int _now = 0;
  static final _last = <ModelVar, ({int at, Unmodeled by})>{};
  static final _met = <UnmodeledMeet>{};

  /// Where each flow last landed a step, on the stamps' clock, keyed by the
  /// fields every table of the flow shares.
  static final _landed = Expando<int>('landed');

  static Set<UnmodeledMeet> get met => Set.unmodifiable(_met);

  @visibleForTesting
  static void forget() => _met.clear();

  static void _meet(
    ActivationStep step, {
    required Set<ModelVar> read,
    required Object flow,
  }) {
    final since = _landed[flow];
    if (since != null) {
      for (final v in read) {
        if (_last[v] case (:final at, :final by) when at > since) {
          _met.add((step: step, by: by, variable: v));
        }
      }
    }
    _landed[flow] = _now;
  }
}

/// A step that read [variable] after [by] wrote it while the step's flow
/// waited.
typedef UnmodeledMeet = ({
  ActivationStep step,
  Unmodeled by,
  ModelVar variable,
});

/// A planted mistake run as code: the tables and definitions the runner
/// takes in place of the code's own while [run]'s body runs, so a test
/// holds the code to a mistake the model's mutants plant (`mutated`,
/// `test/formal_model/mutants.dart`). Nothing outside a test plants one.
final class Planted {
  Planted({
    required Iterable<(StepTable<Object?, Enum>, StepTable<Object?, Enum>)>
    tables,
    required this.defs,
  }) {
    for (final (code, planted) in tables) {
      _tables[code] = planted;
    }
  }

  final Map<StepTable<Object?, Enum>, StepTable<Object?, Enum>> _tables =
      Map.identity();

  /// Each definition the code calls by its name, with the one run instead.
  final Map<ModelDef, Def<Object?, Object?>> defs;

  static const _key = #plantedMistake;

  R run<R>(R Function() body) => runZoned(body, zoneValues: {_key: this});

  StepTable<Object?, Enum>? _table(StepTable<Object?, Enum> code) =>
      _tables[code];

  static Planted? get _current => switch (Zone.current[_key]) {
    final Planted p => p,
    _ => null,
  };
}

/// The environment's actions of `activation.tla` the code writes the
/// model's variables in, hand-written there until the tables print them.
enum Environment {
  /// The frame that builds a loaded site's webview for its active tab and
  /// hands it the back stack queued for that tab (`Frame(s)`).
  frame,

  /// A row moved to another place in the list (`Move(from, to)`).
  move,

  /// A loaded site's webview let go of so the frame builds it afresh
  /// (`LetGo(s)`): a changed posture, proxy, user script, Tor binding or
  /// address, a data clear, a reset, a renderer gone (BUG-002).
  letGo,
}

/// The writes of the model's state that no step of a table takes yet.
enum Unmodeled {
  /// The move to a tab the site runs itself before an owner URL loads
  /// (LIR-018), for a site whose tabs are off, which the model does not
  /// follow; a site with tabs takes the tab input `OwnerRun`.
  ownerRunTab,

  /// Link tabs that run as another site, and the slots that let go of
  /// their webview for it, where the flips are not one site's own link
  /// tabs, which the reroute step takes (LIR-024, LIR-034): several sites'
  /// at once, as an import may, or a tab another site opened.
  identityChange,

  /// A change to the set of sites no step takes: an add, an import, an
  /// archive's open, a site's edit (`SiteSetCommit.commit`). A delete and
  /// an archive's close land in their drop's step, and a move is the
  /// environment's.
  siteSet,

  /// A site moved into an archive or back out, on the other tier's
  /// container.
  archiveMove,

}

/// An input the code marks by hand ([ActivationSteps.mark]) and what it
/// writes of the model, in one synchronous turn: [writes] runs with the
/// input's [Commit], then the step is marked.
void commitInput(
  ActivationStep step, {
  required StepOutcome outcome,
  required Object? site,
  required void Function(Commit commit) writes,
}) {
  writes(const Commit._());
  ActivationSteps.mark(step, outcome: outcome, site: site);
}

/// A variable of the model that is a function of a key (`tabs[s]`), as
/// the state that owns it keeps it: read anywhere, written only with a
/// [Commit], which a table's arm ([Indexed.over]), a hand-marked input
/// ([commitInput]) or a named debt ([Commit.unmodeled]) gives; or, where
/// the model holds only a value's [members], rearranged without one.
final class SharedAt<K, V> {
  SharedAt(
    this.variable, {
    required V Function(K at) read,
    required void Function(K at, {required V to}) write,
    this.members,
  }) : _read = read,
       _write = write;

  final ModelVar variable;
  final V Function(K at) _read;
  final void Function(K at, {required V to}) _write;

  /// What the model holds of a value when it holds a set of it: `tabs[s]`
  /// is the ids of the tabs, not their order or their tree.
  final Set<Object?> Function(V value)? members;

  V of(K at) => _read(at);

  void write({required K at, required V to, required Commit commit}) {
    _write(at, to: to);
    commit.wrote(variable);
  }

  /// A write the model cannot see, so no step takes it: [to] holds the
  /// members the value holds now (a tab dragged within its tree, TAB-015).
  void rearrange({required K at, required V to}) {
    final held = members;
    assert(held != null, '${variable.name}: the model holds all of it');
    if (held != null) {
      final now = held(of(at));
      final then = held(to);
      assert(now.length == then.length && now.containsAll(then),
          '${variable.name}: a rearrangement changed what the model holds');
    }
    _write(at, to: to);
  }
}

/// A variable of the model that is a function, `name[k]`, read and
/// written one entry at a time; the platform's is [Indexed.remote].
final class Indexed<K, V, W> {
  const Indexed(
    ModelVar variable, {
    required V Function(W world, {required K at}) read,
    required void Function(W world, {required K at, required V to}) write,
  }) : _variable = variable,
       _fixed = null,
       _read = read,
       _write = write;

  /// The view a table takes of a [SharedAt] variable, under the name the
  /// owner gave it: its arms write it in the runner's [Commit].
  factory Indexed.over(ModelVar variable, {required SharedAt<K, V> cell}) {
    assert(cell.variable == variable, '${cell.variable.name} is not ${variable.name}');
    return Indexed(
      variable,
      read: (_, {required at}) => cell.of(at),
      write: (_, {required at, required to}) =>
          cell.write(at: at, to: to, commit: const Commit._()),
    );
  }

  const Indexed.remote(ModelVar variable)
    : _variable = variable,
      _fixed = null,
      _read = null,
      _write = null;

  /// One the code reads but only the platform writes: a webview's bound
  /// tab, which the frame that builds the webview sets. A write of it
  /// prints, and the platform does it.
  const Indexed.reported(
    ModelVar variable, {
    required V Function(W world, {required K at}) read,
  }) : _variable = variable,
       _fixed = null,
       _read = read,
       _write = null;

  /// A constant function of the model (`Base`), read only.
  const Indexed.fixed(
    ModelConst of, {
    required V Function(W world, {required K at}) read,
  }) : _variable = null,
       _fixed = of,
       _read = read,
       _write = null;

  final ModelVar? _variable;
  final ModelConst? _fixed;
  String get name => _variable?.name ?? _fixed!.tla;
  final V Function(W world, {required K at})? _read;
  final void Function(W world, {required K at, required V to})? _write;

  Expr<V, W> at(Expr<K, W> k) => Expr._(
    run: (c) {
      if (_variable case final v?) _reading?.add(v);
      return switch (_read) {
        final read? => read(c._world, at: k.run(c)),
        null => throw StateError('$name is read only through a call'),
      };
    },
    tla: '$name[${k.tla}]',
    reads: Reads(vars: {?_variable}) + k.reads,
    literal: _fixed,
  );

  /// `name' = [name EXCEPT ![k] = <to>]`.
  Write<W> except(Expr<K, W> k, {required Expr<V, W> to}) => Write._(
    _variable ?? (throw StateError('$name is a constant of the model')),
    to: '[$name EXCEPT ![${k.tla}] = ${to.tla}]',
    reads: Reads(vars: {_variable}) + k.reads + to.reads,
    stage: (c) {
      final write = _write;
      if (write == null) return () {};
      final key = k.run(c);
      final value = to.run(c);
      return () => write(c._world, at: key, to: value);
    },
  );
}

/// A set of the model the code knows by membership, `e \in name`: a
/// member needs a world that fills it.
final class Members<E, W> {
  const Members(
    this.of, {
    required bool Function(W world, {required E member}) test,
  }) : _test = test;

  final ModelConst of;
  String get name => of.tla;
  final bool Function(W world, {required E member}) _test;

  Expr<bool, W> has(Expr<E, W> e) => Expr._(
    run: (c) => _test(c._world, member: e.run(c)),
    tla: '${tlaOperand(e.tla)} \\in $name',
    reads: e.reads,
    needs: _needs(of),
  );
}

/// A shared variable's new value once a call lands or an act runs:
/// `name' = <to>`, its value read over the state the step found ([stage])
/// and taken by the engine's state once every write of its act is read.
final class Write<W> {
  const Write._(
    this.variable, {
    required this.to,
    required this.reads,
    required this.stage,
  });

  final ModelVar variable;
  String get name => variable.name;
  final String to;
  final Reads reads;

  /// Reads the new value over [StepView]'s state and returns the write
  /// that puts it in.
  final void Function() Function(StepView<W> c) stage;

  /// `name' = <to>`.
  String get tla => "$name' = ${tlaOperand(to)}";
}

/// A ghost of the model, a flag only an invariant reads (`~evictedShown`):
/// the step sets it when [never] holds, `name' = name \/ (never)`, and the
/// code, which keeps no such flag, asserts there that [never] does not.
Write<W> ghost<W>(
  ModelVar variable, {
  required Expr<bool, W> never,
  required String why,
}) => Write._(
  variable,
  to: '${variable.name} \\/ (${never.tla})',
  reads: Reads(vars: {variable}) + never.reads,
  stage: (c) {
    assert(!never.run(c), why);
    return () {};
  },
);

/// A value a flow of world [W] keeps between its awaits, as `fl[f].<tla>`
/// in the model. Read and written only through its own methods, so the
/// field's type, not inference, decides what a step may put in it. Two
/// tables of one flow name a shared field each with their own world: the
/// name is the field.
final class Field<T, W> {
  const Field(this.field);

  final FlowField field;
  String get tla => field.name;

  @override
  bool operator ==(Object other) => other is Field && other.tla == tla;

  @override
  int get hashCode => tla.hashCode;

  /// Its value in [flow].
  T of(StepView<W> flow) {
    assert(flow._fields.containsKey(this), '$tla read before it was set');
    return flow._fields[this] as T;
  }

  /// Whether a step has set it: a flow's `kind` before its input's step.
  bool isSet(StepView<W> flow) => flow._fields.containsKey(this);

  /// Sets the field, as a step's effect does ([becomes]) or as the input
  /// that starts a flow does.
  void put(StepView<W> flow, {required T value}) =>
      flow._fields[this] = value;

  Expr<T, W> get value => Expr._(run: of, tla: 'fl[f].$tla', reads: Reads.none);

  /// Its value, [none] until a step sets it, as the model's row starts.
  Expr<T, W> valueOr({required T none}) {
    assert(tlaOf(none) == field.none, '$tla starts as ${field.none}');
    return Expr._(
      run: (c) => isSet(c) ? of(c) : none,
      tla: 'fl[f].$tla',
      reads: Reads.none,
    );
  }

  /// `fl[f].<field> = <to>`.
  Assign<W> becomes(Expr<T, W> to) => Assign._(
    field: field,
    to: to.tla,
    reads: to.reads,
    run: (c) => put(c, value: to.run(c)),
  );

  /// The field takes a value only the platform holds ([to] names it): the
  /// model records it, the code keeps nothing, so a read is an assert.
  Assign<W> fromPlatform(Expr<Object?, W> to) => Assign._(
    field: field,
    to: to.tla,
    reads: to.reads,
    run: (c) => c._fields.remove(this),
  );

  /// The field holds nothing until a step sets it again, [none] in the
  /// model (`0`, `{}`): a read before then is an assert.
  Assign<W> cleared({required Object none}) => Assign._(
    field: field,
    to: tlaOf(none),
    reads: Reads.none,
    run: (c) => c._fields.remove(this),
  );

  /// A call whose reply this field keeps, the reply being [reply] in the
  /// model; the step's arms read the field as the reply, since it lands
  /// before they run.
  Call<W> receives({
    required Future<T> Function(StepView<W> c) run,
    required Expr<Object?, W> reply,
    List<Assign<W>> reads = const [],
    Set<ModelVar> reaches = const {},
  }) => Call._(
    run: (c) async => put(c, value: await run(c)),
    writes: const [],
    reads: reads,
    reaches: reaches,
    keeps: (field: field, reply: reply.tla, reads: reply.reads),
  );

  /// [receives], the call made on [port].
  Call<W> receivesOn<I>(
    Port<I, W> port, {
    required Future<T> Function(PortView<I, W> c) run,
    required Expr<Object?, W> reply,
    List<Assign<W>> reads = const [],
  }) => receives(
    run: (c) => run(port._view(c)),
    reply: reply,
    reads: reads,
    reaches: port.reads,
  );

  @override
  String toString() => tla;
}

/// The set a step picks from: the code takes its first element in order,
/// or the one [first] names among them, the model any (`\E s \in`).
final class Pick<E, W> {
  const Pick(this.from, {this.first, this.name = 's'});

  final Expr<Iterable<E>, W> from;
  final E Function(StepView<W> c, {required List<E> among})? first;

  /// The bound name, `s` unless an arm picks beside its step's pick.
  final String name;

  /// The element picked, [name] in the model.
  Expr<E, W> get it =>
      Expr._(run: (c) => c._picked[name] as E, tla: name, reads: Reads.none);

  void _make(StepView<W> c) {
    final among = from.run(c).toList();
    c._picked[name] = switch (first) {
      null => among.first,
      final pick => pick(c, among: among),
    };
  }
}

/// What a table reaches of its world beyond its leaves, declared once with
/// the variables of the model its uses read ([reads]) and may change
/// ([changes]): the platform a call acts on ([Call.on]), or an answer a
/// guard or a definition run by name reads ([from]). The code gets the
/// interface, never the world, so what a step reaches is what its table
/// declared.
final class Port<I, W> {
  const Port(
    this.name, {
    required this.reads,
    required this.changes,
    required I Function(W world) of,
  }) : _of = of;

  final String name;
  final Set<ModelVar> reads;
  final Set<ModelVar> changes;
  final I Function(W world) _of;

  /// The interface in [c]'s world, for code of the table that declared it.
  I from(StepView<W> c) {
    _reading?.addAll(reads);
    return _of(c._world);
  }

  /// The interface a call on the port is made through. What the platform
  /// reads while the call is out is its step's, at the reply
  /// ([Call.reaches]), not a read of the turn that issues it.
  PortView<I, W> _view(StepView<W> c) => PortView._(c, api: _of(c._world));

  bool _covers(Iterable<Write<W>> writes) =>
      writes.every((w) => changes.contains(w.variable));

  String _uncovered(Iterable<Write<W>> writes) =>
      '$name changes ${changes.map((v) => v.name).toList()}, not '
      '${[for (final w in writes) if (!changes.contains(w.variable)) w.name]}';
}

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

/// What the model does that the code leaves to its structure: the jar's
/// turn is the SerialQueue's, held while a flow runs in the table and
/// passed on when it leaves; a witness only the model keeps.
Act<W> modelOnly<W>(
  String tla, {
  required Set<ModelVar> writes,
  required Reads reads,
}) => Act(writes: writes, tla: tla, reads: reads, run: (_) {});

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

/// The call a step waits on: what the code calls, and what its landing does
/// to the model: the shared variables it [writes] (the platform's own, so
/// the call is the write), and the field that [keeps] its reply
/// ([Field.receives]). A call reads the state as it starts, which its reply
/// may find changed: what the write needs of that state the flow records
/// as the call is issued ([reads]), in the model on the arm that enters the
/// call's place, so the place is entered by name.
final class Call<W> {
  const Call({
    required Future<void> Function(StepView<W> c) run,
    required this.writes,
    this.reads = const [],
    this.reaches = const {},
    this.then,
  }) : _run = run,
       keeps = null;

  const Call._({
    required Future<void> Function(StepView<W> c) run,
    required this.writes,
    required this.reads,
    required this.reaches,
    required this.keeps,
  }) : _run = run,
       then = null;

  /// A call on [port], whose writes the port must change.
  static Call<W> on<I, W>(
    Port<I, W> port, {
    required Future<void> Function(PortView<I, W> c) run,
    required List<Write<W>> writes,
    List<Assign<W>> reads = const [],
    void Function(CommitView<W> c)? then,
  }) {
    assert(port._covers(writes), port._uncovered(writes));
    return Call(
      run: (c) => run(port._view(c)),
      writes: writes,
      reads: reads,
      reaches: port.reads,
      then: then,
    );
  }

  final Future<void> Function(StepView<W> c) _run;
  final List<Write<W>> writes;
  final List<Assign<W>> reads;

  /// What the platform reads of the model's variables while the call is
  /// out ([Call.on]: its port's), which the model takes at the reply: a read
  /// of the call's own step.
  final Set<ModelVar> reaches;

  /// What the code does as the reply lands, in the step's turn before its
  /// arm's effects: its half of [writes] where the code holds the variable
  /// for the platform, as [Act.of]'s does for an arm.
  final void Function(CommitView<W> c)? then;
  final ({FlowField field, String reply, Reads reads})? keeps;
}

/// How a step ends: as [outcome], doing [then], and going on to [next];
/// an arm of its own [pick] picks once it is taken (`\E s \in` inside the
/// branch), so each arm may pick from a set of its own, and names the
/// [site] it marks, else the step's, and the [tab] it picked, which the
/// mark carries beside the site and the model's label names.
sealed class Arm<W, P extends Enum> {
  const Arm(
    this.outcome, {
    this.pick,
    this.site,
    this.tab,
    required this.then,
    required this.next,
  });

  final StepOutcome outcome;
  final Pick<Object?, W>? pick;
  final Expr<Object?, W>? site;
  final Expr<TabId, W>? tab;
  final List<Effect<W>> then;

  /// Where the flow goes: a place of the table, the same one to go round
  /// again, or one no step waits at, which leaves the table.
  final Expr<P, W> next;
}

/// The arm a step takes when [when] holds, tried in order.
final class Branch<W, P extends Enum> extends Arm<W, P> {
  const Branch(
    super.outcome, {
    required this.when,
    super.pick,
    super.site,
    super.tab,
    required super.then,
    required super.next,
  });

  final Expr<bool, W> when;
}

/// The arm a step takes when none of its [Branch]es holds.
final class Otherwise<W, P extends Enum> extends Arm<W, P> {
  const Otherwise(
    super.outcome, {
    super.pick,
    super.site,
    super.tab,
    required super.then,
    required super.next,
  });
}

/// The arm a step takes when its call fails as [refusal] names, in place
/// of its own: in the model the reply's alternative, open only where [when]
/// holds (a world lets the platform refuse), and the call's writes are not
/// made. Any other failure goes on to the flow's caller. A choice it needs
/// after is the step it goes on to.
final class Refused<W, P extends Enum> extends Arm<W, P> {
  const Refused({
    required this.refusal,
    required this.when,
    super.site,
    required super.then,
    required super.next,
  }) : super(StepOutcome.refused);

  final Refusal<Object> refusal;
  final Expr<bool, W> when;
}

/// The failure, an [E], that a platform call answers with when it refuses
/// ([Refused]).
final class Refusal<E extends Object> {
  const Refusal();

  /// Whether [call] was refused.
  Future<bool> _refuses(Future<void> call) async {
    try {
      await call;
      return false;
    } on E {
      return true;
    }
  }
}

/// The place [place], as the model's `pc` names it: the enum value's name.
Expr<P, W> to<P extends Enum, W>(P place) => Expr.constant(place);

/// What a table answers for a place of its flow: a [Step] that waits
/// there, a table nested there ([Within]), or nothing ([Leaves]).
sealed class At<W, P extends Enum> {
  const At();
}

/// The place is one of a table nested in this flow, which [run] enters at
/// it over a view of the flow ([StepContext.sharing]) and which returns
/// the place it left by. That table prints its own steps.
final class Within<W, P extends Enum> extends At<W, P> {
  const Within(this.run);

  final Future<P> Function(StepView<W> c, {required P from}) run;
}

/// No step of this table waits there: a flow leaves the table by it.
final class Leaves<W, P extends Enum> extends At<W, P> {
  const Leaves();
}

/// One step: what has to hold while a flow waits at its place ([holds]),
/// for what (a [call], or the jar's turn when [granted]; neither for a step
/// that runs on from the one before, between two awaits), the element it
/// [pick]s, and its branches. An arm's effects, its next place and the
/// step's [site] are read over the state the step found, as the model's
/// primed variables are.
final class Step<W, P extends Enum> extends At<W, P> {
  const Step(
    this.name, {
    required this.holds,
    this.granted = false,
    this.call,
    this.pick,
    this.site,
    this.tab,
    this.branches = const [],
    required this.otherwise,
    this.refused,
  }) : input = false,
       spawned = false,
       enabled = null;

  /// An input's own step, the first of the flow it starts, run before any
  /// await: in the model an `Input`, landing while every flow waits, on the
  /// flow numbered next, when [enabled] holds (asserted on the way in; the
  /// caller decides what to do with an input that is not).
  const Step.input(
    this.name, {
    this.enabled,
    this.pick,
    this.site,
    this.tab,
    this.branches = const [],
    required this.otherwise,
  }) : input = true,
       spawned = false,
       holds = null,
       granted = false,
       call = null,
       refused = null;

  /// An input only a [Spawn] starts, in the turn of the step that spawns
  /// it, under the spawn's condition: the model prints it in that step's
  /// action and nowhere else, and the runner asserts it lands nowhere else.
  const Step.spawned(
    this.name, {
    this.pick,
    this.site,
    this.tab,
    this.branches = const [],
    required this.otherwise,
  }) : input = true,
       spawned = true,
       enabled = null,
       holds = null,
       granted = false,
       call = null,
       refused = null;

  final ActivationStep name;
  final bool input;
  final bool spawned;
  final Expr<bool, W>? enabled;

  /// What a flow at the step's place needs: asserted as it moves in and
  /// again when its call returns, and printed as one conjunct of the
  /// model's `Inv_Places`, so the check the code runs is the invariant TLC
  /// and TLAPS hold every interleaving to. Null when the place needs
  /// nothing.
  final Expr<bool, W>? holds;
  final bool granted;
  final Call<W>? call;
  final Pick<Object?, W>? pick;

  /// The site the step names when it marks itself, and the tab it picked.
  final Expr<Object?, W>? site;
  final Expr<TabId, W>? tab;
  final List<Branch<W, P>> branches;
  final Otherwise<W, P> otherwise;

  /// What the step takes when its call is refused, if it can be.
  final Refused<W, P>? refused;

  String get action => name.action;

  /// The arms the step takes when its call answers.
  List<Arm<W, P>> get arms => [...branches, otherwise];

  /// Every arm, the refused one among them.
  List<Arm<W, P>> get allArms => [...arms, ?refused];

  Arm<W, P> _taken(StepView<W> flow) {
    for (final b in branches) {
      if (b.when.run(flow)) return b;
    }
    return otherwise;
  }

  /// Whether the step runs between two awaits: nothing lands before it.
  bool get internal => call == null && !granted && !input;

  Step<W, P> withArms({
    List<Branch<W, P>>? branches,
    Otherwise<W, P>? otherwise,
    Refused<W, P>? refused,
  }) => spawned
      ? Step.spawned(
          name,
          pick: pick,
          site: site,
          tab: tab,
          branches: branches ?? this.branches,
          otherwise: otherwise ?? this.otherwise,
        )
      : input
      ? Step.input(
          name,
          enabled: enabled,
          pick: pick,
          site: site,
          tab: tab,
          branches: branches ?? this.branches,
          otherwise: otherwise ?? this.otherwise,
        )
      : Step(
          name,
          holds: holds,
          granted: granted,
          call: call,
          pick: pick,
          site: site,
          tab: tab,
          branches: branches ?? this.branches,
          otherwise: otherwise ?? this.otherwise,
          refused: refused ?? this.refused,
        );
}

/// The steps of one flow, by the place each waits at, run by [run] and
/// printed by [tla]. [at] answers every value of [P]: the compiler holds it
/// to one answer per place.
final class StepTable<W, P extends Enum> {
  StepTable(
    List<P> places, {
    required At<W, P> Function(P place) at,
    this.ending = const {},
    this.awaited = const {},
    this.vars = const [],
  }) : _at = {for (final p in places) p: at(p)} {
    assert(
      vars.every((v) => v._read != null),
      'a variable the platform holds is read only through a call',
    );
    for (final (:place, :step) in steps) {
      assert(
        step.refused == null || step.call != null,
        '${step.name} at ${place.name} is refused with no call to refuse',
      );
      for (final arm in step.allArms) {
        assert(
          step.name.outcomes.contains(arm.outcome),
          '${step.name} at ${place.name} cannot end as ${arm.outcome}',
        );
      }
    }
  }

  final Map<P, At<W, P>> _at;

  /// The places a flow ends at: an arm going there prints as the flow's
  /// record reset (`NoFlow`), not as a move of its `pc`.
  final Set<P> ending;

  /// The places a flow reaches by returning from a nested table ([Within]):
  /// that return is an await, so a step there is a reply, not a step that
  /// runs on from the one before.
  final Set<P> awaited;

  /// The model's variables the steps read from the engine's state. A step's
  /// effects leave each as they found it unless the arm declares the write
  /// (an [Act]), asserted after every step: the frame the model prints as
  /// `UNCHANGED` is the one the code keeps.
  final List<Var<Object?, W>> vars;

  At<W, P> at(P place) => _at[place] ?? const Leaves();

  /// Every place of the table, a step's or not.
  Iterable<P> get places => _at.keys;

  /// The steps of this table, by place; a nested table's are its own.
  List<({P place, Step<W, P> step})> get steps => [
    for (final MapEntry(key: place, value: at) in _at.entries)
      if (at case final Step<W, P> step) (place: place, step: step),
  ];

  /// The model's variables [name] declares it writes when it ends as
  /// [outcome]: its call's and those of each arm that ends so; null when
  /// no step of this table is [name].
  Set<ModelVar>? writesOf(ActivationStep name, {required StepOutcome outcome}) {
    Set<ModelVar>? out;
    for (final (place: _, :step) in steps) {
      if (step.name != name) continue;
      out = {
        ...?out,
        if (outcome != StepOutcome.refused)
          for (final w in step.call?.writes ?? <Write<W>>[]) w.variable,
        for (final arm in step.allArms)
          if (arm.outcome == outcome)
            for (final e in arm.then)
              if (e case Act(:final writes)) ...writes,
      };
    }
    return out;
  }

  /// The places a step runs on from without an await (`Internal` in the
  /// model): no event lands while a flow is at one.
  List<P> get internalPlaces => [
    for (final (:place, :step) in steps)
      if (step.internal && !awaited.contains(place)) place,
  ];

  /// Runs the flow from [from] until it leaves the table, and returns the
  /// place it left by: each step waits on its call, takes its first branch
  /// that holds, does its effects, marks itself and goes where the branch
  /// says.
  Future<P> run(StepContext<W> c, {required P from}) {
    if (Planted._current?._table(this) case final StepTable<W, P> planted) {
      return planted._run(c, from: from);
    }
    return _run(c, from: from);
  }

  Future<P> _run(StepContext<W> c, {required P from}) async {
    var place = from;
    while (true) {
      switch (at(place)) {
        case Leaves():
          return place;
        case Within(:final run):
          place = await run(c, from: place);
        case final Step<W, P> step:
          _assertHolds(step, place: place, flow: c, when: 'on the way in');
          _enter(step, on: c);
          var refused = false;
          if (step.call case final call?) {
            final issued = _charged(
              _enteredBy[c._fields] ?? step.name,
              run: (_) {
                for (final r in call.reads) {
                  r.run(c);
                }
                return call._run(c);
              },
            );
            switch (step.refused) {
              case null:
                await issued;
              case final r:
                refused = await r.refusal._refuses(issued);
                assert(
                  !refused || r.when.run(c),
                  '${step.name} was refused where ${r.when.tla} does not hold',
                );
            }
            _assertHolds(
              step,
              place: place,
              flow: c,
              when: 'when its call returned',
            );
          }
          place = _land(step, on: c, refused: refused);
      }
    }
  }

  /// Runs the input step at [from], before any await: the first step of the
  /// flow [c] is, and the place it goes on to. An input lands outside any
  /// gate the flow then takes, so its step runs on its own.
  P runInput(StepContext<W> c, {required P from}) {
    if (Planted._current?._table(this) case final StepTable<W, P> planted) {
      return planted._runInput(c, from: from);
    }
    return _runInput(c, from: from);
  }

  P _runInput(StepContext<W> c, {required P from}) {
    final step = at(from);
    assert(step is Step<W, P> && step.input, '${from.name} is no input');
    step as Step<W, P>;
    _enter(step, on: c);
    return _land(step, on: c);
  }

  /// [step]'s pick made and its guard asserted on [on], read as its action
  /// reads them. A spawned input's are its spawner's, whose spawn binds the
  /// pick (`_spawned`, printed as the spawn's `site`), so what the set it
  /// ranges over reads is read by neither.
  void _enter(Step<W, P> step, {required StepContext<W> on}) {
    void enter() {
      if (step.spawned) {
        _unread(() => step.pick?._make(on));
      } else {
        step.pick?._make(on);
      }
      assert(
        step.enabled?.run(on) ?? true,
        'the input ${step.name} ran while ${step.enabled?.tla} did not hold',
      );
    }

    if (step.spawned) {
      enter();
    } else {
      _charged(step.name, run: (_) => enter());
    }
  }

  /// The step's reply landed, or its input ran: its first branch that
  /// holds is taken, its effects done, the step marked, and then the inputs
  /// it spawns started, each marking its own step after this one.
  P _land(
    Step<W, P> step, {
    required StepContext<W> on,
    bool refused = false,
  }) {
    final c = on;
    final outerLanding = _landing;
    final action = _landing = step.spawned
        ? outerLanding ?? step.name
        : step.name;
    try {
      return _charged(
        action,
        run: (reading) {
          final next = _landReading(step, on: c, refused: refused);
          assert(() {
            (StepReads._read[action] ??= {}).addAll(step.call?.reaches ?? {});
            return true;
          }());
          UnmodeledWrites._meet(step.name, read: reading, flow: c._fields);
          _enteredBy[c._fields] = action;
          return next;
        },
      );
    } finally {
      _landing = outerLanding;
    }
  }

  P _landReading(
    Step<W, P> step, {
    required StepContext<W> on,
    required bool refused,
  }) {
    final c = on;
    if (step.input) _admit(step.name, spawned: step.spawned);
    final arm = refused ? step.refused! : step._taken(c);
    arm.pick?._make(c);
    final next = arm.next.run(c);
    final site = (arm.site ?? step.site)?.run(c);
    final tab = (arm.tab ?? step.tab)?.run(c);
    Map<String, Object?>? found;
    assert(() {
      found = _unread(
        () => {for (final v in vars) v.name: _snapshot(v.value.run(c))},
      );
      return true;
    }());
    final outer = _turn;
    final turn = _turn = _Turn(step.name);
    try {
      if (!refused) step.call?.then?.call(CommitView._(c));
      for (final e in arm.then) {
        if (e is! Spawn<W>) e.run(c);
      }
      assert(turn.keptToSpawns);
      assert(_unread(() => _framed(c, found: found!, step: step, arm: arm)));
      ActivationSteps.mark(step.name, outcome: arm.outcome, site: site, tab: tab);
      for (final e in arm.then) {
        if (e is Spawn<W>) e.run(c);
      }
      assert(turn.keptToSpawns);
    } finally {
      _turn = outer;
    }
    return next;
  }

  /// Whether the input step at [place] would run on [c]: its pick made and
  /// its [Step.enabled] holding, read as its action reads them. The caller
  /// of an input that is not decides what to answer; the step asserts it
  /// again on the way in.
  bool admits(P place, {required StepContext<W> on}) {
    final c = on;
    final step = at(place);
    assert(step is Step<W, P> && step.input, '${place.name} is no input');
    step as Step<W, P>;
    return _charged(
      step.name,
      run: (_) {
        step.pick?._make(c);
        return step.enabled?.run(c) ?? true;
      },
    );
  }

  bool _framed(
    StepView<W> c, {
    required Map<String, Object?> found,
    required Step<W, P> step,
    required Arm<W, P> arm,
  }) {
    final declared = {
      // A call's `then` lands its writes inside the turn; a refused one
      // writes nothing.
      if (step.call case Call(then: _?, :final writes) when arm is! Refused)
        for (final w in writes) w.variable,
      for (final e in arm.then)
        if (e is Act<W>) ...e.writes,
    };
    for (final v in vars) {
      if (declared.contains(v.variable)) continue;
      final now = v.value.run(c);
      assert(
        _same(found[v.name], now: now),
        '${step.name} as ${arm.outcome.tla} changed ${v.name}, which it '
        'does not write: ${found[v.name]} -> $now',
      );
    }
    return true;
  }

  /// [value] as a step found it: a collection copied, element by element,
  /// so one the step changes in place is not the value compared after it.
  static Object? _snapshot(Object? value) => switch (value) {
    final Map<Object?, Object?> m => {
      for (final MapEntry(:key, :value) in m.entries) key: _snapshot(value),
    },
    final Iterable<Object?> i => [for (final e in i) _snapshot(e)],
    _ => value,
  };

  /// Equal as the model's values: a collection as the set of its elements,
  /// a function as its entries, each compared so.
  static bool _same(Object? found, {required Object? now}) =>
      switch ((found, now)) {
        (final Map<Object?, Object?> x, final Map<Object?, Object?> y) =>
          x.length == y.length &&
              x.entries.every(
                (e) => y.containsKey(e.key) && _same(e.value, now: y[e.key]),
              ),
        (final Iterable<Object?> x, final Iterable<Object?> y) =>
          x.every((e) => y.any((f) => _same(e, now: f))) &&
              y.every((f) => x.any((e) => _same(e, now: f))),
        _ => found == now,
      };

  static void _assertHolds<W, P extends Enum>(
    Step<W, P> step, {
    required P place,
    required StepView<W> flow,
    required String when,
  }) {
    assert(
      _unread(() => step.holds?.run(flow) ?? true),
      'a flow at ${place.name} does not hold ${step.holds?.tla} $when',
    );
  }
}
