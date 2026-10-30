// The worlds activation.tla is checked in where no world written in
// checks.dart can take two actions whose footprints meet: each pair of
// actions sharing a variable is given the smallest world whose constants
// give both what they need, which allows only the inputs that start them.
// TLC's coverage of every world, written or printed, is what the footprint
// gate holds the pairs to.

import 'checks.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/model_names.dart';

/// The environment's actions, hand-written in `activation.tla` until they
/// are printed: what each reads and writes and needs of the constants, as
/// TLC's coverage names it, which the footprint gate holds to its text.
enum EnvAction {
  move(
    next: r'nested = 0 /\ fore /\ \E from, to \in Pos : Move(from, to)',
    coverage:
        r'InputStep@nested = 0 /\ fore /\ \E from, to \in Pos : Move(from, to)',
    reads: {
      ModelVar.fore,
      ModelVar.gone,
      ModelVar.nested,
      ModelVar.rows,
    },
    writes: {ModelVar.rows},
  ),
  login(
    next: r'\E s \in Sites : Login(s)',
    coverage: 'Login',
    reads: {ModelVar.jar, ModelVar.loaded, ModelVar.signedIn},
    writes: {ModelVar.jar, ModelVar.signedIn},
    needs: {(of: ModelConst.containers, set: false)},
  ),
  clearJar(
    next: 'ClearJar',
    coverage: 'ClearJar',
    reads: {ModelVar.holder, ModelVar.queue},
    writes: {ModelVar.jar, ModelVar.queue},
    needs: {(of: ModelConst.containers, set: false)},
  ),
  viewBuilt(
    next: r'\E s \in Sites : ViewBuilt(s)',
    coverage: 'ViewBuilt',
    reads: {ModelVar.dns, ModelVar.loaded, ModelVar.told},
    writes: {ModelVar.told},
    needs: {(of: ModelConst.dnsLevels, set: true)},
  ),
  // A view is told a level only where a download can pick one, so one
  // goes only there.
  viewGone(
    next: r'\E s \in Sites : ViewGone(s)',
    coverage: 'ViewGone',
    reads: {ModelVar.loaded, ModelVar.told},
    writes: {ModelVar.told},
    needs: {(of: ModelConst.dnsLevels, set: true)},
  ),
  frame(
    next: r'\E s \in Sites : Frame(s)',
    coverage: 'Frame',
    reads: {ModelVar.boxes, ModelVar.loaded, ModelVar.views},
    writes: {ModelVar.boxes, ModelVar.views},
    needs: {(of: ModelConst.boxed, set: true)},
  ),
  letGo(
    next: r'\E s \in Sites : LetGo(s)',
    coverage: 'LetGo',
    reads: {ModelVar.built, ModelVar.hist, ModelVar.loaded},
    writes: {ModelVar.built, ModelVar.hist},
    needs: {
      (of: ModelConst.tabbed, set: true),
      (of: ModelConst.rebuilt, set: true),
    },
  ),
  reframe(
    next: r'\E s \in Sites : Reframe(s)',
    coverage: 'Reframe',
    reads: {
      ModelVar.active,
      ModelVar.built,
      ModelVar.hist,
      ModelVar.loaded,
      ModelVar.queued,
    },
    writes: {ModelVar.built, ModelVar.hist, ModelVar.queued},
    needs: {
      (of: ModelConst.tabbed, set: true),
      (of: ModelConst.rebuilt, set: true),
    },
  );

  const EnvAction({
    required this.next,
    required this.coverage,
    required this.reads,
    required this.writes,
    this.needs = const {},
  });

  /// How `Next` takes it, a case a proof over `Next` splits on.
  final String next;

  /// Its operator in `activation.tla`.
  String get op => '${name[0].toUpperCase()}${name.substring(1)}';

  final String coverage;
  final Set<ModelVar> reads;
  final Set<ModelVar> writes;
  final Set<Need> needs;
}

/// One action of the model as the composition reads it: what it reads and
/// writes of the shared state (other flows' rows apart, as [rows]), the
/// kinds its row holds and the fields of it it writes (null: every one,
/// as an end), each way a flow reaches it: the kind it runs in (null for
/// none), what the constants must be that way and the kinds of flow that
/// spawned it, one entry a way, so a kind two ways reach is listed twice;
/// and each variable only
/// some of its arms write, with what all of those arms need ([armed]).
typedef ComposedAction = ({
  String name,
  Set<ModelVar> reads,
  Set<ModelVar> writes,
  Set<RowRead> rows,
  Set<FlowKind> kinds,
  Set<FlowField>? fields,
  List<({FlowKind? kind, Set<Need> needs, Set<FlowKind> from})> ways,
  Map<ModelVar, Set<Need>> armed,
});

/// The checkers' own variables, which no flow shares.
const _unshared = {ModelVar.last, ModelVar.inputs, ModelVar.seen};

/// Whether [reader] reads a field of a row [writer] can write.
bool _rowsMeet({
  required ComposedAction reader,
  required ComposedAction writer,
}) =>
    reader.rows.any(
      (r) =>
          writer.kinds.contains(r.kind) &&
          (writer.fields?.contains(r.field) ?? true),
    );

/// The variables [a] and [other] share, as the footprint gate reads them:
/// a write the other reads or writes, `fl` only where one reads a field of
/// the other's row.
Set<ModelVar> shared(ComposedAction a, {required ComposedAction other}) => {
  ...{
    ...a.writes.intersection(other.writes),
    ...a.writes.intersection(other.reads),
    ...other.writes.intersection(a.reads),
  }.difference({ModelVar.fl, ..._unshared}),
  if (_rowsMeet(reader: a, writer: other) ||
      _rowsMeet(reader: other, writer: a))
    ModelVar.fl,
};

/// What [a] and [other] meeting over a variable they share needs beyond
/// their ways, one set for each variable and writer: a write only some
/// arms make needs what those arms need, and so does the other's touch
/// of it where it does not read it. A world meets them where it gives any.
List<Set<Need>> _meets(ComposedAction a, {required ComposedAction other}) {
  Set<Need> touch(ComposedAction x, {required ModelVar of}) =>
      x.reads.contains(of) ? const {} : x.armed[of] ?? const {};
  return [
    for (final v in shared(a, other: other))
      if (v == ModelVar.fl)
        const {}
      else ...[
        if (a.writes.contains(v)) {...?a.armed[v], ...touch(other, of: v)},
        if (other.writes.contains(v)) {...?other.armed[v], ...touch(a, of: v)},
      ],
  ];
}

/// Every two of [actions] that share a variable, by name, in order.
List<(String, String, Set<ModelVar>)> meetings(List<ComposedAction> actions) {
  final sorted = [...actions]..sort((a, b) => a.name.compareTo(b.name));
  return [
    for (final (i, a) in sorted.indexed)
      for (final b in sorted.skip(i))
        if (shared(a, other: b) case final vars when vars.isNotEmpty)
          (a.name, b.name, vars),
  ];
}

/// Whether a world setting [constants] gives what [needs] asks.
bool gives(Set<ModelConst> constants, {required Set<Need> needs}) =>
    needs.every((n) => constants.contains(n.of) == n.set);

/// Needs that ask a constant both set and left.
bool _contradicts(Set<Need> needs) =>
    needs.any((n) => needs.contains((of: n.of, set: !n.set)));

/// Whether [w] sets one operator two ways: needs no one world gives,
/// as a router's contending slots beside the one process-wide proxy.
bool _replacesTwice(WorldSpec w) =>
    {for (final e in w.env) e.op}.length != w.env.length;

/// What a world needs besides an operator it replaces, for the replaced
/// one to matter: a route split needs two routes contending, and so on.
Set<Env> _with(Env e) => switch (e) {
  Env.proxyGlobal || Env.globalProxy => {
    Env.proxyGlobal,
    Env.globalProxy,
    Env.routeSplit,
  },
  Env.routerContending || Env.routerShared => {
    Env.routerContending,
    Env.routerShared,
    Env.routeSplit,
  },
  Env.torOn || Env.exitSplit => {Env.torOn, Env.exitSplit},
  Env.exitPair => {Env.torOn, Env.exitPair},
  Env.notifyAll || Env.wakesUp => {Env.notifyAll, Env.wakesUp},
  Env.dnsAsk || Env.dnsTwo => {Env.dnsAsk, Env.dnsTwo},
  Env.residentOne || Env.capTwo => {Env.residentOne, Env.capTwo},
  Env.routeSplit ||
  Env.awaySpaces ||
  Env.linkAny ||
  Env.linkTab ||
  Env.archiveOne ||
  Env.deleteOne ||
  Env.resetOne ||
  Env.rebuildOne ||
  Env.incognitoOne ||
  Env.jarRefuses ||
  Env.proxyRefuses ||
  Env.offline => const {},
};

/// The operator a world replaces to set [c], where one does.
Env? _setting(ModelConst c, {required Set<Need> needs}) => switch (c) {
  ModelConst.away => Env.awaySpaces,
  ModelConst.contending =>
    needs.contains((of: ModelConst.routed, set: true))
        ? Env.routerContending
        : Env.proxyGlobal,
  ModelConst.routed => Env.routerShared,
  ModelConst.globalProxy => Env.globalProxy,
  ModelConst.links => Env.linkTab,
  ModelConst.route => Env.routeSplit,
  ModelConst.linked => Env.linkAny,
  ModelConst.torRuntime => Env.torOn,
  ModelConst.torExit => Env.exitSplit,
  ModelConst.notified => Env.notifyAll,
  ModelConst.waking => Env.wakesUp,
  ModelConst.siteLevel => Env.dnsAsk,
  ModelConst.dnsLevels => Env.dnsTwo,
  ModelConst.maxResident => Env.residentOne,
  ModelConst.maxLoaded => Env.capTwo,
  ModelConst.archive || ModelConst.noNavState || ModelConst.boxed =>
    Env.archiveOne,
  ModelConst.deletable => Env.deleteOne,
  ModelConst.resettable => Env.resetOne,
  ModelConst.rebuilt => Env.rebuildOne,
  ModelConst.incognito => Env.incognitoOne,
  ModelConst.jarRefuses => Env.jarRefuses,
  ModelConst.proxyRefused => Env.proxyRefuses,
  ModelConst.online => Env.offline,
  ModelConst.containers ||
  ModelConst.coldStart ||
  ModelConst.tabbed ||
  ModelConst.maxTabs ||
  ModelConst.sites ||
  ModelConst.base => null,
};

/// A world printed for the pairs no written world can take: its
/// constants, the inputs it allows, and the pairs it was made for.
typedef PrintedWorld = ({
  String cfg,
  WorldSpec spec,
  List<(String, String)> pairs,
});

/// The smallest world that gives [needs] and allows the inputs that start
/// a flow of each of [kinds] ([inputsOf]) and [own], the inputs among the
/// pair themselves.
WorldSpec _worldFor(
  Set<Need> needs, {
  required Set<FlowKind> kinds,
  required Set<String> own,
  required Map<FlowKind, Set<String>> inputsOf,
}) {
  final env = <Env>{
    for (final (:of, :set) in needs)
      if (set)
        if (_setting(of, needs: needs) case final e?) ...{e, ..._with(e)},
  };
  final coldStart = needs.contains((of: ModelConst.coldStart, set: true));
  final tabbed =
      needs.contains((of: ModelConst.tabbed, set: true)) ||
      needs.contains((of: ModelConst.maxTabs, set: true));
  final waking = env.contains(Env.wakesUp);
  // A reset's landing takes a tabbed site among the reset's (`ResetOne`,
  // site 3), so a world needing both tabs site 3 beside site 1.
  final resets = needs.contains((of: ModelConst.resettable, set: true));
  return (
    cookies: needs.contains((of: ModelConst.containers, set: true))
        ? Cookies.containers
        : Cookies.sharedJar,
    coldStart: coldStart,
    inputs: 3,
    tabbed: tabbed ? (resets ? const {1, 3} : const {1}) : const {},
    maxTabs: tabbed ? 3 : 1,
    env: env,
    allowed: {
      ...own,
      for (final k in kinds) ...?inputsOf[k],
      if (waking) ...{'Background', 'Foreground'},
    },
  );
}

/// The worlds to print for every pair of [actions] that meet and that no
/// world of [written] gives both what they need, one world per setting;
/// and the pairs no world can (each asks a constant the other's way
/// leaves).
({List<PrintedWorld> worlds, List<(String, String)> apart}) printWorlds({
  required List<ComposedAction> actions,
  required List<WorldSpec> written,
  required Set<String> inputs,
  required Map<FlowKind, Set<String>> inputsOf,
}) {
  final hosts = [for (final w in written) (spec: w, constants: constantsOf(w))];
  final byWorld = <String, PrintedWorld>{};
  final apart = <(String, String)>[];
  final sorted = [...actions]..sort((a, b) => a.name.compareTo(b.name));
  for (final (i, a) in sorted.indexed) {
    for (final b in sorted.skip(i)) {
      if (shared(a, other: b).isEmpty) continue;
      WorldSpec? best;
      var hosted = false;
      final meets = _meets(a, other: b);
      for (final (kind: ka, needs: na, from: fa) in a.ways) {
        for (final (kind: kb, needs: nb, from: fb) in b.ways) {
          for (final m in meets) {
            final needs = {...na, ...nb, ...m};
            if (_contradicts(needs)) continue;
            final w = _worldFor(
              needs,
              kinds: {?ka, ?kb, ...fa, ...fb},
              own: {
                for (final x in [a, b])
                  if (inputs.contains(x.name)) x.name,
              },
              inputsOf: inputsOf,
            );
            if (_replacesTwice(w)) continue;
            if (hosts.any(
              (h) =>
                  gives(h.constants, needs: needs) &&
                  (h.spec.allowed?.containsAll(w.allowed!) ?? true),
            )) {
              hosted = true;
            }
            if (best == null || _cost(w) < _cost(best)) best = w;
          }
        }
      }
      if (hosted) continue;
      if (best == null) {
        apart.add((a.name, b.name));
        continue;
      }
      // One world per setting of the constants, allowing every input any
      // of its pairs needs.
      final key = _slug(best);
      final was = byWorld[key];
      byWorld[key] = (
        cfg: 'activation_gen_$key',
        spec: (
          cookies: best.cookies,
          coldStart: best.coldStart,
          inputs: best.inputs,
          tabbed: best.tabbed,
          maxTabs: best.maxTabs,
          env: best.env,
          allowed: {...?was?.spec.allowed, ...?best.allowed},
        ),
        pairs: [...?was?.pairs, (a.name, b.name)],
      );
    }
  }
  return (
    worlds: [for (final k in byWorld.keys.toList()..sort()) byWorld[k]!],
    apart: apart,
  );
}

int _cost(WorldSpec w) =>
    w.env.length +
    (w.allowed?.length ?? 99) +
    (w.coldStart ? 2 : 0) +
    (w.tabbed.isEmpty ? 0 : 2);

/// A world's name from its constants: its isolation, launch, tabs and the
/// operators it replaces.
String _slug(WorldSpec w) => [
  if (w.cookies == Cookies.containers) 'containers' else 'jar',
  if (w.coldStart) 'cold',
  if (w.tabbed.isNotEmpty) 'tabs',
  for (final e in (w.env.toList()..sort((a, b) => a.name.compareTo(b.name))))
    _snake(e.name),
].join('_');

String _snake(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
