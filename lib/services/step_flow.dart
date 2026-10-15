import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';

/// A flow written in the order it runs: the input that starts it, each
/// place it waits at, and what it decides between two awaits, compiled to
/// the [Step]s of a table ([FlowInput.steps]), which run and print as any
/// table's do. The next place of each arm is the await it goes on to, so no
/// arm names one by hand unless it leaves for another table's place.
sealed class Then<W, P extends Enum> {
  const Then();

  /// The place an arm going on to this enters.
  Expr<P, W> get place;
}

/// The flow goes to [place]: one a nested table runs, one no step of this
/// flow waits at, or one computed from the state.
final class GoTo<W, P extends Enum> extends Then<W, P> {
  const GoTo(this.place);

  @override
  final Expr<P, W> place;
}

/// The flow waits at [at] for its [call] (or the jar's turn when
/// [granted]), then decides as [decide] says.
final class Await<W, P extends Enum> extends Then<W, P> {
  const Await(
    this.name, {
    required this.at,
    required this.holds,
    this.granted = false,
    this.call,
    this.pick,
    this.site,
    this.tab,
    required this.decide,
  });

  final P at;
  final ActivationStep name;
  final Expr<bool, W>? holds;
  final bool granted;
  final Call<W>? call;
  final Pick<Object?, W>? pick;
  final Expr<Object?, W>? site;
  final Expr<TabId, W>? tab;
  final Decide<W, P> decide;

  @override
  Expr<P, W> get place => to(at);
}

/// What a flow decides between two awaits: conditions tried in order
/// ([When], and [over] a reply's values), and the ends that close the step
/// ([Ends]).
sealed class Decide<W, P extends Enum> {
  const Decide();
}

/// [then] when [when] holds over the shared state, else [otherwise].
final class When<W, P extends Enum> extends Decide<W, P> {
  const When(this.when, {required this.then, required this.otherwise});

  final Expr<bool, W> when;
  final Ends<W, P> then;
  final Decide<W, P> otherwise;
}

/// A decision over a value the flow holds ([value], a reply or a field)
/// that takes one of [values]: [decide] is plain Dart over the value, run
/// once per value as the flow is built, so it sees the value and nothing of
/// the shared state, and each value but the last prints as its own
/// condition.
Decide<W, P> over<R, W, P extends Enum>(
  Expr<R, W> value, {
  required List<R> values,
  required Decide<W, P> Function(R value) decide,
}) {
  assert(values.isNotEmpty, 'a decision over ${value.tla} has no values');
  var rest = decide(values.last);
  for (final v in values.reversed.skip(1)) {
    final taken = decide(v);
    assert(
      taken is Ends<W, P>,
      'the decision for ${value.tla} = $v decides again: give it its own '
      'condition',
    );
    rest = When(
      value.eq(Expr.constant(v)),
      then: taken as Ends<W, P>,
      otherwise: rest,
    );
  }
  return rest;
}

/// How a step ends: as [outcome], doing [does], and going on to [next].
final class Ends<W, P extends Enum> extends Decide<W, P> {
  const Ends(
    this.outcome, {
    this.pick,
    this.site,
    this.tab,
    this.does = const [],
    required this.next,
  });

  final StepOutcome outcome;
  final Pick<Object?, W>? pick;
  final Expr<Object?, W>? site;
  final Expr<TabId, W>? tab;
  final List<Effect<W>> does;
  final Then<W, P> next;

  Branch<W, P> _when(Expr<bool, W> when) => Branch(
    outcome,
    when: when,
    pick: pick,
    site: site,
    tab: tab,
    then: does,
    next: next.place,
  );

  /// This end as a step's last arm: where a mutant puts one in a step.
  Otherwise<W, P> get otherwise => Otherwise(
    outcome,
    pick: pick,
    site: site,
    tab: tab,
    then: does,
    next: next.place,
  );
}

/// An input: the flow's first step, landing while every flow waits.
final class FlowInput<W, P extends Enum> {
  const FlowInput(
    this.name, {
    required this.at,
    this.enabled,
    this.pick,
    this.site,
    this.tab,
    required this.decide,
  });

  final P at;
  final ActivationStep name;
  final Expr<bool, W>? enabled;
  final Pick<Object?, W>? pick;
  final Expr<Object?, W>? site;
  final Expr<TabId, W>? tab;
  final Decide<W, P> decide;

  /// The steps the flow waits at, by place, in the order it reaches them.
  Map<P, Step<W, P>> get steps {
    final out = <P, Step<W, P>>{};
    final (:branches, :otherwise) = _arms(decide);
    out[at] = Step.input(
      name,
      enabled: enabled,
      pick: pick,
      site: site,
      tab: tab,
      branches: branches,
      otherwise: otherwise,
    );
    final reached = <P, Await<W, P>>{};
    void visit(Decide<W, P> d) {
      for (final end in _ends(d)) {
        if (end.next case final Await<W, P> a) {
          if (reached[a.at] case final seen?) {
            assert(identical(seen, a), 'two steps wait at ${a.at.name}');
            continue;
          }
          assert(a.at != at, 'a step waits at the input\'s place ${at.name}');
          reached[a.at] = a;
          final (:branches, :otherwise) = _arms(a.decide);
          out[a.at] = Step(
            a.name,
            holds: a.holds,
            granted: a.granted,
            call: a.call,
            pick: a.pick,
            site: a.site,
            tab: a.tab,
            branches: branches,
            otherwise: otherwise,
          );
          visit(a.decide);
        }
      }
    }

    visit(decide);
    return out;
  }

  static ({List<Branch<W, P>> branches, Otherwise<W, P> otherwise})
  _arms<W, P extends Enum>(Decide<W, P> d) {
    final branches = <Branch<W, P>>[];
    var rest = d;
    while (true) {
      switch (rest) {
        case When(when: final condition, :final then, :final otherwise):
          branches.add(then._when(condition));
          rest = otherwise;
        case final Ends<W, P> end:
          return (branches: branches, otherwise: end.otherwise);
      }
    }
  }

  static Iterable<Ends<W, P>> _ends<W, P extends Enum>(Decide<W, P> d) sync* {
    switch (d) {
      case When(:final then, :final otherwise):
        yield then;
        yield* _ends(otherwise);
      case final Ends<W, P> end:
        yield end;
    }
  }
}
