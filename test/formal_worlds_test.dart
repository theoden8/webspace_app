import 'package:flutter_test/flutter_test.dart';
import 'formal_model/checks.dart';
import 'formal_model/worlds.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/model_names.dart';

ComposedAction _act(
  String name, {
  Set<ModelVar> reads = const {},
  Set<ModelVar> writes = const {},
  required Map<FlowKind?, Set<Need>> ways,
  Map<ModelVar, Set<Need>> armed = const {},
}) => (
  name: name,
  reads: reads,
  writes: writes,
  rows: const {},
  kinds: const {},
  fields: const {},
  ways: [
    for (final MapEntry(:key, :value) in ways.entries)
      (kind: key, needs: value),
  ],
  armed: armed,
);

const WorldSpec _plain = (
  cookies: Cookies.sharedJar,
  coldStart: false,
  inputs: 3,
  tabbed: {},
  maxTabs: 1,
  env: {},
  allowed: null,
);

final _open = _act(
  'NestedOpen',
  writes: {ModelVar.nested},
  ways: {
    FlowKind.nested: {(of: ModelConst.linked, set: true)},
  },
);
final _tab = _act(
  'OpenTab',
  reads: {ModelVar.nested},
  ways: {
    FlowKind.tab: {(of: ModelConst.tabbed, set: true)},
  },
);

({List<PrintedWorld> worlds, List<(String, String)> apart}) _print(
  List<ComposedAction> actions, {
  required List<WorldSpec> written,
}) => printWorlds(
  actions: actions,
  written: written,
  inputs: {'NestedOpen', 'OpenTab'},
  inputsOf: {
    FlowKind.nested: {'NestedOpen'},
    FlowKind.tab: {'OpenTab'},
  },
);

void main() {
  test('a pair no written world can take is printed a world of its own', () {
    final world = _print([_open, _tab], written: [_plain]).worlds.singleWhere(
      (w) => w.pairs.contains(('NestedOpen', 'OpenTab')),
    );
    expect(world.spec.env, {Env.linkAny}, reason: 'the nested open needs links');
    expect(world.spec.tabbed, {1}, reason: 'the tab input needs a tabbed site');
    expect(world.spec.allowed, {'NestedOpen', 'OpenTab'},
        reason: 'only the inputs that start the two flows');
  });

  test('a pair a written world gives its needs prints nothing', () {
    final hosting = (
      cookies: Cookies.sharedJar,
      coldStart: false,
      inputs: 3,
      tabbed: const {1},
      maxTabs: 3,
      env: const {Env.linkAny},
      allowed: null,
    );
    expect(_print([_open, _tab], written: [_plain, hosting]).worlds, isEmpty);
  });

  test('a pair whose needs contradict is taken by no world', () {
    final jar = _act(
      'Login',
      reads: {ModelVar.nested},
      ways: {
        null: {(of: ModelConst.containers, set: false)},
      },
    );
    final boxed = _act(
      'ContReply',
      writes: {ModelVar.nested},
      ways: {
        FlowKind.tap: {(of: ModelConst.containers, set: true)},
      },
    );
    final printed = _print([jar, boxed], written: [_plain]);
    expect(printed.apart, contains(('ContReply', 'Login')));
  });

  test('a write only some arms make meets where those arms are taken', () {
    final flip = _act(
      'RerouteFlip',
      writes: {ModelVar.loaded},
      ways: {
        FlowKind.tab: {(of: ModelConst.tabbed, set: true)},
      },
      armed: {
        ModelVar.loaded: {(of: ModelConst.globalProxy, set: true)},
      },
    );
    final gone = _act(
      'ViewGone',
      reads: {ModelVar.loaded},
      ways: {
        null: {(of: ModelConst.dnsLevels, set: true)},
      },
    );
    final world = _print([flip, gone], written: [_plain]).worlds.singleWhere(
      (w) => w.pairs.contains(('RerouteFlip', 'ViewGone')),
    );
    expect(world.spec.env, containsAll({Env.globalProxy, Env.dnsTwo}),
        reason: 'only the arm under one process-wide proxy unloads');
  });

  test('a tabbed site on a routed slot is printed a world (LIR-024)', () {
    final routed = _act(
      'RoutesReply',
      writes: {ModelVar.nested},
      ways: {
        FlowKind.tap: {(of: ModelConst.routed, set: true)},
      },
    );
    final printed = _print([routed, _tab], written: [_plain]);
    final world = printed.worlds.singleWhere(
      (w) => w.pairs.contains(('OpenTab', 'RoutesReply')),
    );
    expect(world.spec.tabbed, {1}, reason: 'the tab input needs a tabbed site');
    expect(world.spec.env, contains(Env.routerShared),
        reason: 'the reply needs a routed slot');
    expect(printed.apart, isEmpty);
  });
}
