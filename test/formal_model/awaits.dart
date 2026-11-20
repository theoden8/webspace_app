import 'dart:math';

import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/model_names.dart';

/// The most awaits a flow an input starts can take before it ends, read off
/// the printed footprints. An await is a step whose turn is a reply or a
/// lock's turn granted; code between two awaits costs none. Places a flow
/// can go round between are one group, costing every await in it once, so
/// [awaits] bounds every path that takes each place once; each group whose
/// round holds an await is a [loops] entry, named by its first place, whose
/// rounds the table's own data bounds (the sites an unload walks), not its
/// places.
typedef AwaitCeiling = ({
  ActivationStep input,
  int awaits,
  List<String> path,
  List<({String at, int awaits})> loops,
});

int _cost(StepTurn turn) => switch (turn) {
  StepTurn.reply || StepTurn.granted => 1,
  StepTurn.input || StepTurn.between || StepTurn.environment => 0,
};

/// One ceiling per input the footprints name, in their order.
List<AwaitCeiling> awaitCeilings(List<Footprint> all) {
  final byPlace = <String, List<Footprint>>{};
  for (final f in all) {
    if (!f.input && f.turn != StepTurn.environment) {
      byPlace.putIfAbsent(f.place, () => []).add(f);
    }
  }
  Set<String> nexts(Iterable<Footprint> fs) => {
    for (final f in fs)
      for (final a in f.arms)
        if (!a.ends) ...a.next.keys.where(byPlace.containsKey),
  };
  final edges = {
    for (final MapEntry(key: p, value: fs) in byPlace.entries) p: nexts(fs),
  };
  final group = _groups(edges);
  final members = <String, List<String>>{};
  for (final p in byPlace.keys) {
    members.putIfAbsent(group[p]!, () => []).add(p);
  }
  int costOf(String g) => members[g]!
      .map((p) => byPlace[p]!.map((f) => _cost(f.turn)).reduce(max))
      .fold(0, (a, b) => a + b);
  bool loops(String g) => members[g]!.length > 1 || edges[g]!.contains(g);
  final after = {
    for (final g in members.keys)
      g: {
        for (final p in members[g]!)
          for (final n in edges[p]!)
            if (group[n] != g) group[n]!,
      },
  };
  final best = <String, ({int awaits, List<String> path})>{};
  ({int awaits, List<String> path}) from(String g) => best[g] ??= () {
    var top = (awaits: 0, path: const <String>[]);
    for (final n in after[g]!) {
      final rest = from(n);
      if (rest.awaits > top.awaits) top = rest;
    }
    return (awaits: costOf(g) + top.awaits, path: [g, ...top.path]);
  }();
  return [
    for (final f in all)
      if (f.input)
        () {
          final starts = {
            for (final n in nexts([f])) group[n]!,
          };
          var top = (awaits: 0, path: const <String>[]);
          final seen = <String>{};
          void visit(String g) {
            if (!seen.add(g)) return;
            after[g]!.forEach(visit);
          }

          for (final g in starts) {
            visit(g);
            final rest = from(g);
            if (rest.awaits > top.awaits) top = rest;
          }
          return (
            input: f.step,
            awaits: top.awaits,
            path: top.path,
            loops: [
              for (final g in seen)
                if (loops(g) && costOf(g) > 0) (at: g, awaits: costOf(g)),
            ]..sort((a, b) => a.at.compareTo(b.at)),
          );
        }(),
  ];
}

/// Each place's group, named by its first member in [edges]' order: the
/// places reachable from each other (Tarjan's strongly connected parts).
Map<String, String> _groups(Map<String, Set<String>> edges) {
  final index = <String, int>{}, low = <String, int>{};
  final stack = <String>[], onStack = <String>{};
  final order = {for (final (i, p) in edges.keys.indexed) p: i};
  final group = <String, String>{};
  var next = 0;
  void connect(String v) {
    index[v] = low[v] = next++;
    stack.add(v);
    onStack.add(v);
    for (final w in edges[v]!) {
      if (!index.containsKey(w)) {
        connect(w);
        low[v] = min(low[v]!, low[w]!);
      } else if (onStack.contains(w)) {
        low[v] = min(low[v]!, index[w]!);
      }
    }
    if (low[v] == index[v]) {
      final part = <String>[];
      String w;
      do {
        w = stack.removeLast();
        onStack.remove(w);
        part.add(w);
      } while (w != v);
      part.sort((a, b) => order[a]!.compareTo(order[b]!));
      for (final p in part) {
        group[p] = part.first;
      }
    }
  }

  for (final v in edges.keys) {
    if (!index.containsKey(v)) connect(v);
  }
  return group;
}

/// [all] with one more await on the flow [on] starts, the planted mistake
/// `formal/await_ceilings.py` must refuse: the first place on its heaviest
/// path whose code ran between two awaits now waits on a reply, as a step
/// that gains a platform call does.
List<Footprint> oneMoreAwait(
  List<Footprint> all, {
  required ActivationStep on,
}) {
  final path = awaitCeilings(all).firstWhere((c) => c.input == on).path;
  final place = path.firstWhere(
    (p) => all
        .where((f) => f.place == p && !f.input)
        .every((f) => f.turn == StepTurn.between),
    orElse: () => throw StateError('${on.action} awaits at every place'),
  );
  return [
    for (final f in all)
      if (f.place == place && !f.input)
        (
          step: f.step,
          place: f.place,
          input: f.input,
          turn: StepTurn.reply,
          reads: f.reads,
          writes: f.writes,
          needs: f.needs,
          guard: f.guard,
          arms: f.arms,
        )
      else
        f,
  ];
}

/// The ceilings as the TSV `formal/await_ceilings.py` holds to its floor.
String activationAwaits(List<Footprint> all) => [
  '# input\tmost awaits to its end\tloops (place:awaits a round)\tthe heaviest path, by group',
  for (final c in awaitCeilings(all))
    [
      c.input.action,
      c.awaits,
      c.loops.isEmpty
          ? '-'
          : c.loops.map((l) => '${l.at}:${l.awaits}').join(' '),
      c.path.isEmpty ? '-' : c.path.join(' '),
    ].join('\t'),
  '',
].join('\n');
