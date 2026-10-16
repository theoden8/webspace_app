import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_flow.dart';
import 'package:webspace/services/step_table.dart';

/// A world whose one reply is whether the device is online.
final class _World {
  bool online = true;
  bool stale = false;
}

enum _Place { input, wait, done }

final _world = Port<_World, _World>(
  'world',
  reads: const {},
  changes: const {},
  of: (w) => w,
);
final _stale = Expr.op<bool, _World>(
  'Stale(f)',
  run: (c) => _world.from(c).stale,
  reads: const Reads(defs: {ModelDef.stale}),
);
final _online = Expr.op<bool, _World>(
  'Online',
  run: (c) => _world.from(c).online,
  reads: Reads.none,
);
final _logged = <String>[];
final _done = GoTo<_World, _Place>(to(_Place.done));

FlowInput<_World, _Place> _flow({required Decide<_World, _Place> decide}) =>
    FlowInput(
      ActivationStep.spaceSwitch,
      at: _Place.input,
      decide: Ends(
        StepOutcome.none,
        next: Await(
          ActivationStep.spaceOnlineReply,
          at: _Place.wait,
          holds: null,
          call: Call(run: (_) async {}, writes: const []),
          decide: decide,
        ),
      ),
    );

StepTable<_World, _Place> _table(Map<_Place, Step<_World, _Place>> steps) =>
    StepTable(
      _Place.values,
      ending: {_Place.done},
      at: (place) => steps[place] ?? const Leaves(),
    );

String _printed(StepTable<_World, _Place> t) =>
    t.tla(variables: [ModelVar.fl, ModelVar.last]);

void main() {
  test('a flow compiles to the steps a hand-written table holds', () {
    final flow = _flow(
      decide: When(
        _stale,
        then: Ends(StepOutcome.stale, next: _done),
        otherwise: When(
          ~_online,
          then: Ends(StepOutcome.skip, next: _done),
          otherwise: Ends(StepOutcome.go, next: _done),
        ),
      ),
    );
    final byHand = {
      _Place.input: Step<_World, _Place>.input(
        ActivationStep.spaceSwitch,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(_Place.wait),
        ),
      ),
      _Place.wait: Step<_World, _Place>(
        ActivationStep.spaceOnlineReply,
        holds: null,
        call: Call(run: (_) async {}, writes: const []),
        branches: [
          Branch(
            StepOutcome.stale,
            when: _stale,
            then: [],
            next: to(_Place.done),
          ),
          Branch(
            StepOutcome.skip,
            when: ~_online,
            then: [],
            next: to(_Place.done),
          ),
        ],
        otherwise: Otherwise(StepOutcome.go, then: [], next: to(_Place.done)),
      ),
    };
    expect(flow.steps.keys, [_Place.input, _Place.wait]);
    expect(_printed(_table(flow.steps)), _printed(_table(byHand)));
  });

  test('a decision over a reply prints one condition per value', () async {
    final flow = _flow(
      decide: over(
        _online,
        values: [true, false],
        decide: (online) => online
            ? Ends(StepOutcome.go, next: _done)
            : Ends(
                StepOutcome.skip,
                does: [Note((_) => _logged.add('offline'))],
                next: _done,
              ),
      ),
    );
    final wait = flow.steps[_Place.wait]!;
    expect([for (final b in wait.branches) b.when.tla], ['Online = TRUE']);
    expect(wait.otherwise.outcome, StepOutcome.skip);

    _logged.clear();
    final c = StepContext(_World()..online = false);
    final table = _table(flow.steps);
    await table.run(c, from: table.runInput(c, from: _Place.input));
    expect(_logged, ['offline']);
  });

  test('two steps waiting at one place are refused', () {
    Await<_World, _Place> wait() => Await(
      ActivationStep.spaceOnlineReply,
      at: _Place.wait,
      holds: null,
      decide: Ends(StepOutcome.go, next: _done),
    );
    final flow = FlowInput<_World, _Place>(
      ActivationStep.spaceSwitch,
      at: _Place.input,
      decide: When(
        _stale,
        then: Ends(StepOutcome.none, next: wait()),
        otherwise: Ends(StepOutcome.none, next: wait()),
      ),
    );
    expect(() => flow.steps, throwsA(isA<AssertionError>()));
  });

  test('a value that decides again before the last is refused', () {
    expect(
      () => over<bool, _World, _Place>(
        _online,
        values: [true, false],
        decide: (online) => online
            ? When(
                _stale,
                then: Ends(StepOutcome.stale, next: _done),
                otherwise: Ends(StepOutcome.go, next: _done),
              )
            : Ends(StepOutcome.skip, next: _done),
      ),
      throwsA(isA<AssertionError>()),
    );
  });
}
