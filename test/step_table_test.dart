import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/formal_model/models.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';

/// A world of one model variable, `loaded`, kept in use order.
final class _World {
  final Set<int> loaded = {1, 2};
}

enum _Place { go, wait, done }

final _loaded = Mutable<Iterable<int>, _World>(
  ModelVar.loaded,
  read: (w) => w.loaded.toSet(),
  write: (w, {required to}) => w.loaded
    ..clear()
    ..addAll(to),
);

/// The world whole, declared to change nothing: a port that lies about
/// what its code changes, for the frame check to catch.
final _lying = Port<_World, _World>(
  'lying',
  reads: const {},
  changes: const {},
  of: (w) => w,
);

/// The world's `loaded`, declared as what the calls below read and change.
final _loadedPort = Port<Set<int>, _World>(
  'loaded',
  reads: {ModelVar.loaded},
  changes: {ModelVar.loaded},
  of: (w) => w.loaded,
);

StepTable<_World, _Place> _table({required List<Effect<_World>> then}) =>
    StepTable(
      _Place.values,
      vars: [_loaded],
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          otherwise: Otherwise(
            StepOutcome.none,
            then: then,
            next: to(_Place.done),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );

void main() {
  test('a declared write is applied by the runner, newest last', () async {
    final c = StepContext(_World());
    final table = _table(
      then: [
        Act.of([
          _loaded.becomes(
            _loaded.value.union(Expr.constant<int, _World>(1).asSet),
          ),
        ]),
      ],
    );
    await table.run(c, from: _Place.go);
    expect(c.world.loaded.toList(), [2, 1]);
    expect(
      table.tla(variables: [ModelVar.loaded, ModelVar.fl, ModelVar.last]),
      contains("loaded' = (loaded \\cup {1})"),
    );
  });

  test('a step whose port changes a variable it does not write is caught', () {
    final c = StepContext(_World());
    final table = _table(then: [Note((c) => _lying.from(c).loaded.add(3))]);
    expect(
      () => table.run(c, from: _Place.go),
      throwsA(
        isA<AssertionError>().having(
          (e) => e.message,
          'message',
          contains('changed loaded, which it does not write'),
        ),
      ),
    );
  });

  test('a call whose writes its port does not change is caught', () {
    expect(
      () => Call.on(
        _lying,
        run: (c) async => c.api.loaded.clear(),
        writes: [_loaded.becomes(Expr.constant<Set<int>, _World>({}, tla: '{}'))],
      ),
      throwsA(
        isA<AssertionError>().having(
          (e) => e.message,
          'message',
          contains('lying changes [], not [loaded]'),
        ),
      ),
    );
  });

  test("a step's footprint is what its declarations read and write", () {
    final table = StepTable<_World, _Place>(
      _Place.values,
      vars: [_loaded],
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          branches: [
            Branch(
              StepOutcome.none,
              when: _loaded.value.isEmpty,
              then: [],
              next: to(_Place.done),
            ),
          ],
          otherwise: Otherwise(
            StepOutcome.none,
            then: [
              Act.of([_loaded.becomes(Expr.none())]),
              modelOnly(
                'Enqueue(f)',
                writes: {ModelVar.queue},
                reads: const Reads(base: {BaseOp.enqueue}),
              ),
            ],
            next: to(_Place.done),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );
    final [(:step, :reads, :writes, :arms, place: _, input: _, needs: _, guard: _)] = table
        .footprints();
    expect(step, ActivationStep.plan);
    expect(reads.vars, {ModelVar.loaded}, reason: 'the branch reads loaded');
    expect(reads.base, {BaseOp.enqueue});
    expect(writes, {ModelVar.loaded, ModelVar.queue, ModelVar.fl, ModelVar.last},
        reason: "its writes, the flow's own row and the step it marks");
    expect([for (final a in arms) a.fields], [
      {FlowField.pc},
      {FlowField.pc},
    ], reason: 'each arm moves only its own pc');
  });

  test("a guard's needs are read off the constants it reads", () {
    final cold = Constant<bool, _World>(ModelConst.coldStart, read: (_) => true);
    final jar = Constant<bool, _World>(ModelConst.containers, read: (_) => false);
    final linked = Members<int, _World>(
      ModelConst.linked,
      test: (_, {required member}) => true,
    );
    final one = Expr.constant<int, _World>(1);
    expect((cold.value & linked.has(one)).needs, {
      (of: ModelConst.coldStart, set: true),
      (of: ModelConst.linked, set: true),
    }, reason: 'a conjunction needs both');
    expect((cold.value | linked.has(one)).needs, isEmpty,
        reason: 'a disjunction needs what both sides do');
    expect((~jar.value).needs, {(of: ModelConst.containers, set: false)},
        reason: 'a switch negated needs the other setting');
    final table = StepTable<_World, _Place>(
      _Place.values,
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          branches: [
            Branch(
              StepOutcome.none,
              when: jar.value,
              then: [],
              next: to(_Place.done),
            ),
          ],
          otherwise: Otherwise(
            StepOutcome.none,
            then: [],
            next: to(_Place.wait),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );
    final [step] = table.footprints();
    expect([for (final a in step.arms) a.needs], [
      {(of: ModelConst.containers, set: true)},
      {(of: ModelConst.containers, set: false)},
    ], reason: 'the arm after a branch on a switch needs its other setting');
  });

  test("a branch on the flow's kind lets only that kind through", () {
    const kind = Field<FlowKind, _World>(FlowField.kind);
    final table = StepTable<_World, _Place>(
      _Place.values,
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          branches: [
            Branch(
              StepOutcome.none,
              when: kind.isKind(FlowKind.dns),
              then: [],
              next: to(_Place.wait),
            ),
          ],
          otherwise: Otherwise(
            StepOutcome.none,
            then: [],
            next: to(_Place.done),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );
    final [step] = table.footprints();
    expect([for (final a in step.arms) a.only], [
      {FlowKind.dns},
      FlowKind.values.toSet().difference({FlowKind.dns}),
    ], reason: 'the arm after a kind test takes every other kind');
    expect((~kind.isKind(FlowKind.dns)).kinds,
        FlowKind.values.toSet().difference({FlowKind.dns}));
  });

  test('a row holds the kind its input gave it until its flow ends', () {
    const kind = Field<FlowKind, _World>(FlowField.kind);
    final table = StepTable<_World, _Place>(
      _Place.values,
      ending: {_Place.done},
      at: (place) => switch (place) {
        _Place.go => Step.input(
          ActivationStep.plan,
          otherwise: Otherwise(
            StepOutcome.none,
            then: [kind.becomes(Expr.constant(FlowKind.dns))],
            next: to(_Place.wait),
          ),
        ),
        _Place.wait => Step(
          ActivationStep.plan,
          holds: null,
          otherwise: Otherwise(
            StepOutcome.none,
            then: [],
            next: to(_Place.done),
          ),
        ),
        _Place.done => const Leaves(),
      },
    );
    final all = table.footprints();
    expect(kindsAt(all), {
      'wait': {FlowKind.dns},
    }, reason: 'the input gives its row the kind; the end leaves none');
    final [input, wait] = all;
    expect(input.arms.single.fields, {FlowField.pc, FlowField.kind});
    expect(wait.arms.single.ends, isTrue);
    expect(
      Expr.inFlight<_World>(FlowKind.dns, run: (_) => false).reads.rows,
      {(kind: FlowKind.dns, field: FlowField.kind)},
      reason: 'a flow in flight is read off the kind of the rows of its kind',
    );
  });

  test('a variable its owner shares is written only through a write', () async {
    final owner = <int>{1};
    final shared = Shared.ofSet(owner, variable: ModelVar.loaded);
    final view = Mutable<Iterable<int>, _World>.over(
      ModelVar.loaded,
      of: (_) => shared,
    );
    final c = StepContext(_World());
    expect(view.value.run(c), [1]);
    view.becomes(Expr.constant<List<int>, _World>([2, 3])).apply(c);
    expect(owner, {2, 3});
    expect(shared.value, isNot(same(owner)), reason: 'a read is a fresh copy');
  });

  test('a cell made narrower than the view reaching it fails at its first '
      'read', () {
    // What Dart 3.12's inference made of a cell built with no type
    // arguments: a Set cell where the field holds an Iterable one.
    final Shared<Iterable<Object>> cell = Shared<Set<int>>(
      ModelVar.loaded,
      read: () => {1},
      write: (_) {},
    );
    final view = Mutable<Iterable<Object>, _World>.over(
      ModelVar.loaded,
      of: (_) => cell,
    );
    final c = StepContext(_World());
    final narrower = throwsA(
      isA<AssertionError>().having(
        (e) => e.message,
        'message',
        contains('was made as Shared<Set<int>> but is written as '
            'Shared<Iterable<Object>>'),
      ),
    );
    expect(() => view.value.run(c), narrower);
    expect(
      () => view.becomes(Expr.constant<List<Object>, _World>([2])).apply(c),
      narrower,
    );
  });

  test('a variable the platform holds cannot be among the ones read', () {
    expect(
      () => StepTable<_World, _Place>(
        _Place.values,
        vars: [Mutable.remote(ModelVar.jar)],
        at: (_) => const Leaves(),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('an operand is grouped only where an operator sits at its top', () {
    final a = Expr.constant<int, _World>(1, tla: 'x');
    final b = Expr.op<Iterable<int>, _World>(
      'Share(s, f[1])',
      run: (_) => [], reads: const Reads(defs: {ModelDef.share}),
    );
    expect(b.has(a).tla, 'x \\in Share(s, f[1])');
    expect((a.eq(a) & a.neq(a)).tla, '(x = x) /\\ (x # x)');
  });

  _definitions();
}

enum _Tier { resident, cleared }

void _definitions() {
  final c = StepContext(_World());
  const s = Bound<int, _World>('s');
  final tier = Indexed<int, _Tier, _World>(
    ModelVar.tier,
    read: (_, {required at}) => at == 1 ? _Tier.resident : _Tier.cleared,
    write: (_, {required at, required to}) {},
  );

  test('a quantifier and a set builder bind their variable while they run', () {
    final residents = _loaded.value.where(
      s,
      holds: tier.at(s.it).eq(Expr.constant(_Tier.resident)),
    );
    expect(residents.tla, '{s \\in loaded : tier[s] = "resident"}');
    expect(residents.run(c), [1]);
    final all = _loaded.value.forAll(s, holds: s.it.neq(Expr.constant(3)));
    expect(all.tla, '\\A s \\in loaded : s # 3');
    expect(all.run(c), isTrue);
    expect(
      _loaded.value.exists(s, holds: s.it.eq(Expr.constant(3))).run(c),
      isFalse,
    );
  });

  test('a definition prints once and runs as a call over its arguments', () {
    final cleared = Def<bool, _World>(
      ModelDef.evictable,
      params: [s],
      body: tier.at(s.it).eq(Expr.constant(_Tier.cleared)),
    );
    expect(cleared.tla, 'Evictable(s) == tier[s] = "cleared"');
    final call = cleared.call([Expr.constant(2)]);
    expect(call.tla, 'Evictable(2)');
    expect(call.run(c), isTrue);
    final any = Def<bool, _World>(
      ModelDef.spare,
      body: _loaded.value.exists(s, holds: cleared.call([s.it])),
    );
    expect(any.tla, 'Spare == \\E s \\in loaded : Evictable(s)');
    expect(any.value.tla, 'Spare');
    expect(any.value.run(c), isTrue);
  });

  test('a ghost prints as the model\'s flag and asserts in the code', () {
    final never = _loaded.value.has(Expr.constant<int, _World>(1));
    final w = ghost(ModelVar.evictedShown, never: never, why: 'site 1 is loaded');
    expect(w.to, 'evictedShown \\/ (1 \\in loaded)');
    expect(() => w.apply(c), throwsA(isA<AssertionError>()));
  });

  test('a record\'s part reads the field the model names', () {
    final marker = Expr<({int t, int v}), _World>(
      run: (_) => (t: 2, v: 7),
      tla: 'marker',
      reads: const Reads(vars: {ModelVar.marker}),
    );
    final v = marker.part('v', get: (m) => m.v);
    expect(v.tla, 'marker.v');
    expect(v.run(c), 7);
  });

  test('a field a call receives reads as the reply within its step', () async {
    final got = Field<int, _World>(FlowField.label);
    final table = StepTable<_World, _Place>(
      _Place.values,
      vars: [_loaded],
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          call: got.receivesOn(
            _loadedPort,
            run: (c) async => c.api.length,
            reply: Expr.op(
              'Cardinality(loaded)',
              run: (c) => _loadedPort.from(c).length,
              reads: const Reads(vars: {ModelVar.loaded}),
            ),
          ),
          branches: [
            Branch(
              StepOutcome.none,
              when: got.value.eq(Expr.constant(2)),
              then: [Act.of([_loaded.becomes(Expr.constant<Set<int>, _World>({}, tla: '{}'))])],
              next: to(_Place.done),
            ),
          ],
          otherwise: Otherwise(StepOutcome.none, then: [], next: to(_Place.done)),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );
    final world = _World();
    await table.run(StepContext(world), from: _Place.go);
    expect(world.loaded, isEmpty, reason: 'the branch read the reply');
    final printed = table.tla(variables: [ModelVar.loaded, ModelVar.fl, ModelVar.last]);
    expect(printed, contains('IF (Cardinality(loaded)) = 2'));
    expect(printed, contains('![f].label = Cardinality(loaded)'));
    expect(printed, isNot(contains('IF fl[f].label')));
  });

  group('a step that reads what a write no step takes changed while it '
      'waited is recorded (Phase 4)', () {
    /// `go` lands at once; `wait` waits on [reply], then reads `loaded`.
    StepTable<_World, _Place> table(Future<void> reply) => StepTable(
      _Place.values,
      vars: [_loaded],
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          otherwise: Otherwise(StepOutcome.none, then: [], next: to(_Place.wait)),
        ),
        _Place.wait => Step(
          ActivationStep.applied,
          holds: null,
          call: Call.on(_loadedPort, run: (_) => reply, writes: const []),
          branches: [
            Branch(
              StepOutcome.none,
              when: _loaded.value.isEmpty,
              then: [],
              next: to(_Place.done),
            ),
          ],
          otherwise: Otherwise(StepOutcome.none, then: [], next: to(_Place.done)),
        ),
        _Place.done => const Leaves(),
      },
    );

    Future<Set<UnmodeledMeet>> during(
        void Function() write) async {
      UnmodeledWrites.forget();
      final reply = Completer<void>();
      final run = table(reply.future).run(StepContext(_World()), from: _Place.go);
      await Future<void>.delayed(Duration.zero);
      write();
      reply.complete();
      await run;
      return UnmodeledWrites.met;
    }

    test('an unmodeled write of what the step reads is a meet', () async {
      expect(
        await during(() => const Commit.unmodeled(Unmodeled.rebuild)
            .wrote(ModelVar.loaded)),
        {
          (
            step: ActivationStep.applied,
            by: Unmodeled.rebuild,
            variable: ModelVar.loaded,
          ),
        },
      );
    });

    test('a write the model takes is none', () async {
      expect(
        await during(() => const Commit.fixture().wrote(ModelVar.loaded)),
        isEmpty,
      );
    });

    test('an unmodeled write of what the step does not read is none',
        () async {
      expect(
        await during(() => const Commit.unmodeled(Unmodeled.rebuild)
            .wrote(ModelVar.queued)),
        isEmpty,
      );
    });
  });

  test('a call records what it reads as it starts, on the arm that enters '
      'its place', () async {
    final site = Field<int, _World>(FlowField.site);
    final got = Field<int, _World>(FlowField.label);
    final table = StepTable<_World, _Place>(
      _Place.values,
      vars: [_loaded],
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          otherwise: Otherwise(
            StepOutcome.none,
            then: [site.becomes(Expr.constant(5))],
            next: to(_Place.wait),
          ),
        ),
        _Place.wait => Step(
          ActivationStep.navReply,
          holds: null,
          call: Call.on(
            _loadedPort,
            run: (c) async => c.api.clear(),
            writes: [_loaded.becomes(Expr.constant<Set<int>, _World>({}, tla: '{}'))],
            reads: [
              got.becomes(
                Expr(run: (c) => site.of(c) + 1, tla: 'fl[f].site + 1', reads: Reads.none),
              ),
            ],
          ),
          otherwise: Otherwise(StepOutcome.go, then: [], next: to(_Place.done)),
        ),
        _Place.done => const Leaves(),
      },
    );
    final c = StepContext(_World());
    await table.run(c, from: _Place.go);
    expect(got.of(c), 6, reason: 'read after the arm set the site');
    final printed = table.tla(variables: [ModelVar.loaded, ModelVar.fl, ModelVar.last]);
    expect(printed, contains('![f].pc = "wait", ![f].site = 5, ![f].label = (5) + 1'));
    expect(printed, isNot(contains('![f].label = fl[f].site')));
  });

  group("a step that starts another table's input in its turn (Spawn)", () {
    const kind = Field<FlowKind, _World>(FlowField.kind);
    const site = Field<int, _World>(FlowField.site);
    final each = Pick<int, _World>(
      Expr.op(
        'Listed',
        run: (_) => [2],
        reads: const Reads(base: {BaseOp.listed}),
      ),
    );
    // A tap of site 2, which goes on to wait unless the site is loaded.
    final taps = StepTable<_World, _Place>(
      _Place.values,
      ending: {_Place.done},
      at: (place) => switch (place) {
        _Place.go => Step.input(
          ActivationStep.tap,
          pick: each,
          otherwise: Otherwise(
            StepOutcome.none,
            then: [
              kind.becomes(Expr.constant(FlowKind.tap)),
              site.becomes(each.it),
            ],
            next: Expr.choose(
              when: _loaded.value.has(each.it),
              then: to(_Place.done),
              otherwise: to(_Place.wait),
            ),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );
    final starts = {
      for (final (:step, place: _) in taps.steps) step.name: step,
    };
    // Unloads site 2, then does [then]: a spawn of the tap, or a stray one.
    StepTable<_World, _Place> unloading({
      required Effect<_World> then,
    }) => StepTable(
      _Place.values,
      ending: {_Place.done},
      vars: [_loaded],
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          otherwise: Otherwise(
            StepOutcome.none,
            then: [
              Act.of([
                _loaded.becomes(_loaded.value.without(Expr.constant(2))),
              ]),
              then,
            ],
            next: to(_Place.done),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );
    final reopens = Expr.constant<bool, _World>(true, tla: 'Reopens');
    Spawn<_World> spawn({
      Expr<bool, _World>? when,
      required void Function(StepView<_World> c) start,
    }) => Spawn(
      ActivationStep.tap,
      site: Expr.constant(2),
      when: when ?? reopens,
      start: start,
    );

    test('runs the input after its arm and prints it on the next flow', () async {
      final world = _World();
      late _Place tapped;
      final table = unloading(
        then: spawn(
          start: (_) => tapped = taps.runInput(StepContext(world), from: _Place.go),
        ),
      );
      await table.run(StepContext(world), from: _Place.go);
      expect(tapped, _Place.wait, reason: 'the tap read the loaded sites the arm left');
      final printed = table.tla(
        variables: [ModelVar.loaded, ModelVar.fl, ModelVar.last, ModelVar.inputs],
        starts: starts,
      );
      expect(printed, contains('IF Reopens\n'));
      expect(printed, contains('THEN (LET s == 2 IN (Starts) /\\ '));
      expect(
        printed,
        contains(
          "(fl' = [fl EXCEPT ![f] = NoFlow, ![inputs + 1].pc = IF s \\in loaded' "
          'THEN "done" ELSE "wait", ![inputs + 1].kind = "tap", '
          '![inputs + 1].site = s])',
        ),
        reason: "the input's row, over the loaded sites its arm left",
      );
      expect(printed, contains('(UNCHANGED << inputs >>)'),
          reason: 'the arm that starts none counts no input');
      final [
        (
          :writes,
          :arms,
          reads: _,
          step: _,
          place: _,
          input: _,
          needs: _,
          guard: _,
        ),
      ] = table.footprints(starts: starts);
      expect(writes, contains(ModelVar.inputs));
      final [(:spawns, ends: _, fields: _, kind: _, needs: _, next: _, only: _)] =
          arms;
      final [started] = spawns;
      expect(started.kind, FlowKind.tap);
      expect(started.next.keys, unorderedEquals(['done', 'wait']),
          reason: 'the started row goes where the tap goes');
      expect(table.spawningPlaces, [_Place.go]);
    });

    test('whose condition reads what its arm writes is refused', () {
      final table = unloading(
        then: spawn(when: _loaded.value.has(Expr.constant(1)), start: (_) {}),
      );
      expect(
        () => table.tla(
          variables: [ModelVar.loaded, ModelVar.fl, ModelVar.last, ModelVar.inputs],
          starts: starts,
        ),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message,
            'message',
            contains('reads what its arm writes'),
          ),
        ),
        reason: 'the model reads the condition before the writes, the code after',
      );
    });

    test('whose code starts no input is caught', () {
      final table = unloading(then: spawn(start: (_) {}));
      expect(
        () => table.run(StepContext(_World()), from: _Place.go),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message,
            'message',
            contains('and its code started none'),
          ),
        ),
      );
    });

    // The tap as an input only a spawn starts (WEBSPACE-013's keep): a
    // guardless one in Next once let TLC load a site beside its base.
    final kept = StepTable<_World, _Place>(
      _Place.values,
      ending: {_Place.done},
      at: (place) => switch (place) {
        _Place.go => Step.spawned(
          ActivationStep.tap,
          pick: each,
          otherwise: Otherwise(
            StepOutcome.none,
            then: [
              kind.becomes(Expr.constant(FlowKind.tap)),
              site.becomes(each.it),
            ],
            next: to(_Place.wait),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );

    test('a spawned input lands only by its spawn', () async {
      final world = _World();
      expect(
        () => kept.runInput(StepContext(world), from: _Place.go),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message,
            'message',
            contains('is started only by its Spawn'),
          ),
        ),
      );
      late _Place started;
      await unloading(
        then: spawn(
          start: (_) => started = kept.runInput(StepContext(world), from: _Place.go),
        ),
      ).run(StepContext(world), from: _Place.go);
      expect(started, _Place.wait);
    });

    test('a spawned input prints only in the action of its spawner', () {
      final variables = [
        ModelVar.loaded,
        ModelVar.fl,
        ModelVar.last,
        ModelVar.inputs,
      ];
      expect(kept.tla(variables: variables), isNot(contains('Tap(f) ==')));
      expect(kept.footprints(), isEmpty);
      expect(
        unloading(then: spawn(start: (_) {})).tla(
          variables: variables,
          starts: {for (final (:step, place: _) in kept.steps) step.name: step},
        ),
        contains('![inputs + 1].pc = "wait"'),
      );
    });

    test('an input started in a turn by no spawn is caught', () {
      final world = _World();
      final table = unloading(
        then: Note((_) => taps.runInput(StepContext(world), from: _Place.go)),
      );
      expect(
        () => table.run(StepContext(world), from: _Place.go),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message,
            'message',
            contains('landed in the turn of ActivationStep.plan, which spawns '
                'no such input'),
          ),
        ),
      );
    });
  });

  test('a pick takes the element its rule names among the set', () async {
    final picks = <int>[];
    final world = _World();
    final table = StepTable<_World, _Place>(
      _Place.values,
      vars: [_loaded],
      at: (place) => switch (place) {
        _Place.go => Step(
          ActivationStep.plan,
          holds: null,
          pick: Pick(_loaded.value, first: (_, {required among}) => among.last),
          otherwise: Otherwise(
            StepOutcome.none,
            then: [Note((c) => picks.add(Pick(_loaded.value).it.run(c)))],
            next: to(_Place.done),
          ),
        ),
        _Place.wait || _Place.done => const Leaves(),
      },
    );
    await table.run(StepContext(world), from: _Place.go);
    expect(picks, [2]);
  });
}
