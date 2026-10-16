// What the code declares for formal/, printed: the TLA+ modules the models
// extend, the planted mistakes TLC must catch, and every engine's declared
// model as JSON for the tools that are not TLA+. main.dart writes them; the
// files are derivatives, written under build/formal/ and never committed.
import 'dart:convert';

import 'package:webspace/formal_model/checks.dart';
import 'package:webspace/formal_model/lean_footprints.dart';
import 'package:webspace/formal_model/worlds.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/activation_place.dart';
import 'package:webspace/controllers/activation_flow.dart';
import 'package:webspace/controllers/activation_table.dart';
import 'package:webspace/controllers/site_deletion.dart';
import 'package:webspace/controllers/tab_vars.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_table.dart';

/// One file the checkers read, by its path under the output directory.
typedef PrintedFile = ({String path, String text});

/// The tables the activation model is printed from, and the operators the
/// engines define, in one record so a mutant is the record with one table
/// or one definition replaced.
typedef Tables = ({
  StepTable<ActivationFlow, ActivationPlace> activation,
  StepTable<TabFlow, TabPlace> tabInputs,
  StepTable<TabFlow, TabPlace> tabFlow,
  StepTable<UnloadFlow, UnloadPlace> unload,
  StepTable<UnloadWorld, UnloadPlace> jar,
  StepTable<RestoreWorld, RestorePlace> restore,
  StepTable<WakeFlow<Object>, WakePlace> wake,
  StepTable<DnsFlow, DnsPlace> dns,
  StepTable<CloseFlow, ClosePlace> archive,
  StepTable<DeleteFlow, DeletePlace> delete,
  List<Def<Object?, Object?>> ops,
});

/// Every operator an engine defines, each printed once from the engine
/// that owns the variables it reads (`activation_ops`): the definition
/// each [ModelDef] names, in a switch the compiler holds exhaustive.
Def<Object?, Object?> definition(ModelDef d) => switch (d) {
  ModelDef.evictable => RuntimeVars.evictable<Object>(),
  ModelDef.running => RuntimeVars.runningSites<Object>(),
  ModelDef.midActivation => ActivationTable.midActivation,
  ModelDef.pressureResident => ActivationTable.pressureResident,
  ModelDef.pressureCleared => ActivationTable.pressureCleared,
  ModelDef.stale => ActivationTable.stale,
  ModelDef.conflicts => SiteUnloadEngine.conflicts,
  ModelDef.proxyContenders => SiteUnloadEngine.proxyContenders,
  ModelDef.torDissenters => SiteUnloadEngine.torDissenters,
  ModelDef.routeFree => ActivationTable.routeFree,
  ModelDef.ruled => ActivationTable.ruled,
  ModelDef.kept => ActivationTable.kept,
  ModelDef.picked => SiteUnloadEngine.picked,
  ModelDef.spare => SiteUnloadEngine.spare,
  ModelDef.gone => SiteUnloadEngine.gone,
  ModelDef.share => CookieIsolationEngine.share<Object?>(),
  ModelDef.tabBusy => TabsController.tabBusy,
  ModelDef.capture => TabVars.capture<Object?>(),
  ModelDef.bound => TabVars.bound<Object?>(),
  ModelDef.shown => TabVars.shown<Object?>(),
  ModelDef.taken => TabVars.taken<Object?>(),
  ModelDef.staged => TabVars.staged<Object?>(),
  ModelDef.resolveLevel => resolveLevelDef<Object?>(),
};

final List<Def<Object?, Object?>> definitions = [
  for (final d in ModelDef.values) definition(d),
];

final Tables tables = (
  activation: ActivationTable.activationFlow,
  tabInputs: TabsController.tabInputs,
  tabFlow: TabsController.tabFlow,
  unload: SiteUnloadEngine.unloadFlow,
  jar: CookieIsolationEngine.unloadSteps,
  restore: CookieIsolationEngine.restoreSteps,
  wake: wakeTable<Object>(),
  dns: DnsTable.table,
  archive: ArchiveController.closeTable,
  delete: SiteDeletion.deleteTable,
  ops: definitions,
);

/// The tables the model is printed from, named once: [_all] answers each
/// in a switch the compiler holds exhaustive.
enum ModelTable {
  activation,
  tabInputs,
  tabFlow,
  unload,
  jar,
  restore,
  wake,
  dns,
  archive,
  delete,
}

StepTable<Object?, Enum> _table(Tables t, {required ModelTable of}) =>
    switch (of) {
      ModelTable.activation => t.activation,
      ModelTable.tabInputs => t.tabInputs,
      ModelTable.tabFlow => t.tabFlow,
      ModelTable.unload => t.unload,
      ModelTable.jar => t.jar,
      ModelTable.restore => t.restore,
      ModelTable.wake => t.wake,
      ModelTable.dns => t.dns,
      ModelTable.archive => t.archive,
      ModelTable.delete => t.delete,
    };

List<StepTable<Object?, Enum>> _all(Tables t) => [
  for (final m in ModelTable.values) _table(t, of: m),
];

/// What [step] declares it writes of the model when it ends as [outcome],
/// over every table of [of] (the code's unless a planted mistake's): its
/// call's writes and its arm's; null when no table has the step (an input
/// the code marks by hand, the environment's).
Set<ModelVar>? declaredWrites(
  ActivationStep step, {
  required StepOutcome outcome,
  Tables? of,
}) {
  Set<ModelVar>? out;
  for (final t in _all(of ?? tables)) {
    if (t.writesOf(step, outcome: outcome) case final w?) {
      out = {...?out, ...w};
    }
  }
  return out;
}

/// A table that declares less than its code writes, planted for the walks'
/// frame check to catch (test/activation_schedules_test.dart): the code runs
/// as it is and is held to these tables' declarations, which no step runs.
enum FrameMistake {
  /// The delete's drop leaves out the webview it lets go, as its table did
  /// before the step replay found it.
  deleteDropKeepsWebView,
}

Tables frameMistake(FrameMistake m) => switch (m) {
  FrameMistake.deleteDropKeepsWebView => _with(
    delete: _withArms(
      tables.delete,
      step: ActivationStep.deleteDropReply,
      arms: (s) => Step(
        s.name,
        holds: s.holds,
        granted: s.granted,
        call: Call(
          run: (_) async {},
          writes: [
            for (final w in s.call!.writes)
              if (w.variable != ModelVar.built && w.variable != ModelVar.hist)
                w,
          ],
          reads: s.call!.reads,
        ),
        pick: s.pick,
        site: s.site,
        tab: s.tab,
        branches: s.branches,
        otherwise: s.otherwise,
      ),
    ),
  ),
};

/// What a flow records as it enters any table's place whose call reads at
/// its start, by place name across the tables (a flow crosses them).
Map<String, List<Assign<Object?>>> _entered(Tables t) => {
  for (final table in _all(t)) ...table.readsByPlace,
};

/// Every table's inputs by name, for a step that starts one (`Spawn`).
Map<ActivationStep, Step<Object?, Enum>> _starts(Tables t) => {
  for (final table in _all(t))
    for (final (:step, place: _) in table.steps)
      if (step.input) step.name: step,
};

/// Everything there is to print, in one list: a new engine's model is a new
/// entry here.
List<PrintedFile> printedModels() => [
  (path: 'activation_vars.tla', text: activationVars()),
  (path: 'activation_steps.tla', text: activationSteps()),
  (path: 'activation_ops.tla', text: activationOps(tables)),
  (path: 'activation_tables.tla', text: activationTables(tables)),
  (path: 'activation_tables_proof.tla', text: activationTablesProof(tables)),
  (
    path: 'activation_invariants_proof.tla',
    text: activationInvariantsProof(tables),
  ),
  (path: 'activation_footprints.tsv', text: activationFootprints(tables)),
  (path: 'activation_base_ops.tsv', text: activationBaseOps()),
  (
    path: 'lean/Footprints.lean',
    text: footprintsLean(
      actions: composedActions(tables),
      inputs: {for (final s in _inputSteps(tables)) s.action},
      worlds: [
        for (final w in ActivationWorld.values)
          if (w.holds != null)
            (cfg: w.cfg, spec: w.spec, invariants: w.invariants),
        for (final (:cfg, :spec, pairs: _) in printed.worlds)
          (cfg: cfg, spec: spec, invariants: invariantsOf(spec)),
      ],
    ),
  ),
  (
    path: 'activation_pairs.tsv',
    text: [
      '# action\taction\tthe variables they share',
      for (final (a, b, vars) in meetings(composedActions(tables)))
        '$a\t$b\t${([for (final v in vars) v.name]..sort()).join(' ')}',
      '',
    ].join('\n'),
  ),
  (
    path: 'activation_invariants.tsv',
    text: [
      '# invariant\tat rest\tthe variables it reads',
      for (final i in Inv.values)
        if (i.reads case final reads?)
          '${i.tla}\t${i.atRest}\t${([for (final v in reads) v.name]..sort()).join(' ')}',
      '',
    ].join('\n'),
  ),
  (
    path: 'activation_worlds.tsv',
    text: [
      '# config\tthe constants it sets',
      for (final c in allChecks) _worldLine(c.cfg, spec: c.world),
      '',
    ].join('\n'),
  ),
  (
    path: 'activation_printed_worlds.tsv',
    text: [
      '# config\taction\taction: a pair no written world can take,',
      '# printed a world of its own; and pairs no world can take at all (-)',
      for (final (:cfg, :pairs, spec: _) in printed.worlds)
        for (final (a, b) in pairs) '$cfg\t$a\t$b',
      for (final (a, b) in printed.apart) '-\t$a\t$b',
      '',
    ].join('\n'),
  ),
  for (final m in Mutant.values) ...[
    (path: 'mutants/${m.name}/activation_ops.tla', text: activationOps(mutated(m))),
    (
      path: 'mutants/${m.name}/activation_tables.tla',
      text: activationTables(mutated(m)),
    ),
  ],
  for (final c in allChecks) (path: 'checks/${c.cfg}.cfg', text: c.text),
  (
    path: 'checks.tsv',
    text: [
      for (final c in allChecks)
        [c.cfg, c.expect, c.label, c.mutant?.name ?? ''].join('\t'),
      '',
    ].join('\n'),
  ),
  (
    path: 'models.json',
    text: const JsonEncoder.withIndent('  ').convert(declaredModels()),
  ),
];

String _worldLine(String cfg, {required WorldSpec spec}) =>
    '$cfg\t${([for (final c in constantsOf(spec)) c.tla]..sort()).join(' ')}';

/// Every check, the printed worlds' among them.
final allChecks = activationChecks(
  printed: [
    for (final (:cfg, :spec, :pairs) in printed.worlds)
      (
        cfg: cfg,
        spec: spec,
        label:
            'printed for ${[for (final (a, b) in pairs) '$a/$b'].take(3).join(', ')}'
            '${pairs.length > 3 ? ' and ${pairs.length - 3} more' : ''}',
      ),
  ],
);

/// The worlds printed for the pairs of actions that meet and no written
/// world can take.
final printed = printWorlds(
  actions: composedActions(tables),
  written: [
    for (final w in ActivationWorld.values)
      if (w.holds != null) w.spec,
  ],
  inputs: {for (final s in _inputSteps(tables)) s.action},
  inputsOf: {for (final k in FlowKind.values) k: _inputsOf(k)},
);

/// The inputs a world lets in for a flow of kind [k]: those that start one,
/// and those whose own step writes what a starter's guard reads, which let
/// it land (a webspace switch lands only on the list, where going home puts
/// the screen).
Set<String> _inputsOf(FlowKind k) {
  final inputs = [
    for (final f in _footprintsOf(tables))
      if (f.input) f,
  ];
  final starters = [
    for (final f in inputs)
      if (f.arms.any((a) => a.kind == k)) f,
  ];
  final guard = {for (final f in starters) ...f.guard};
  return {
    for (final f in starters) f.step.action,
    for (final f in inputs)
      if (f.writes.difference({ModelVar.fl, ModelVar.last, ModelVar.inputs})
          .any(guard.contains))
        f.step.action,
  };
}

List<Footprint> _footprintsOf(Tables t) => [
  for (final table in _all(t))
    ...table.footprints(entered: _entered(t), starts: _starts(t)),
];

Reads _resolved(Reads r, {required Set<ModelDef> seen}) => r.defs
    .difference(seen)
    .fold(
      r,
      (sum, d) => sum + _resolved(definition(d).body.reads, seen: {...seen, d}),
    );

/// Every action of the model as the composition reads it: the tables'
/// from their declarations ([stepActions]), the environment's from
/// [EnvAction].
List<ComposedAction> composedActions(Tables t) => [
  for (final (step: _, :action) in stepActions(t)) action,
  for (final e in EnvAction.values)
    (
      name: e.coverage,
      reads: e.reads,
      writes: e.writes,
      rows: const {},
      kinds: const {},
      fields: const {},
      ways: {null: e.needs},
    ),
];

/// Each table step's action as the composition reads it, beside the step
/// it prints from: what a schedule search pairs the steps it ran by.
List<({ActivationStep step, ComposedAction action})> stepActions(Tables t) {
  final all = _footprintsOf(t);
  final flows = flowsAt(all);
  return [
    for (final f in all)
      if (_resolved(f.reads, seen: const {}) case final r)
        (
          step: f.step,
          action: (
            name: f.step.action,
            reads: {...r.vars, for (final b in r.base) ...b.reads},
            writes: {...f.writes, for (final b in r.base) ...b.writes},
            rows: {...r.rows, for (final b in r.base) ...b.rows},
            kinds: {
              if (!f.input) ...?flows[f.place]?.keys,
              for (final a in f.arms) ...[?a.kind, for (final r in a.spawns) r.kind],
            },
            fields: f.arms.any((a) => a.ends)
                ? null
                : {
                    for (final a in f.arms) ...[
                      ...a.fields,
                      for (final r in a.spawns) ...r.fields,
                    ],
                  },
            ways: f.input
                ? {for (final a in f.arms) a.kind: f.needs}
                : {
                    for (final MapEntry(key: k, value: n)
                        in (flows[f.place] ?? const {}).entries)
                      k: {...n, ...f.needs},
                  },
          ),
        ),
  ];
}

/// The model's variables, declared once in [ModelVar], and a flow's empty
/// record, from [FlowField]: what `activation_base` extends.
String activationVars() => [
  '----------------------------- MODULE activation_vars --------------------------',
  '(* Printed from ModelVar and FlowField by lib/formal_model/main.dart.     *)',
  '(* Not committed; edit the enums.                                         *)',
  '',
  'VARIABLES',
  for (final (i, v) in ModelVar.values.indexed)
    '    ${'${v.name}${i < ModelVar.values.length - 1 ? ',' : ''}'.padRight(12)}\\* ${v.doc}',
  '',
  r'\* A flow no input has started: its record with nothing in it.',
  'NoFlow == [${[for (final f in FlowField.values) '${f.name} |-> ${f.none}'].join(', ')}]',
  '=============================================================================',
  '',
].join('\n');

/// Every step of `activation.tla` and the branches it can take, from
/// [ActivationStep], and the places the tables' steps run on from without
/// an await.
String activationSteps() => [
  '---------------------------- MODULE activation_steps --------------------------',
  '(* Printed from ActivationStep and the step tables by                      *)',
  '(* lib/formal_model/main.dart.                                            *)',
  '',
  r'\* Every action and the branches it can take, as the code marks them.',
  'Outcomes == [',
  [
    for (final s in ActivationStep.values)
      '    ${s.action} |-> {${[for (final o in s.outcomes) '"${o.tla}"'].join(', ')}}',
  ].join(',\n'),
  '    ]',
  '',
  r'\* The actions that start a flow (Step.input), which land only where',
  r'\* activation_base says an input may (Lands).',
  'Inputs == {${[for (final s in _inputSteps(tables)) '"${s.action}"'].join(', ')}}',
  '',
  r"\* The tables' steps between two awaits: no event lands at these places.",
  'Internal_Tables == {${[for (final t in _all(tables))
    for (final p in t.internalPlaces) '"${p.name}"'].join(', ')}}',
  '',
  r'\* The places whose step starts another input in its own turn (Spawn),',
  r'\* which past the last input has no flow to start it on.',
  'Spawning_Tables == {${[for (final t in _all(tables))
    for (final p in t.spawningPlaces) '"${p.name}"'].join(', ')}}',
  '',
  r"\* The inputs only a spawn starts (Step.spawned): a replay folds each one's",
  r"\* mark into the step that spawned it, whose action prints it.",
  'Spawned_Inputs == {${[for (final t in _all(tables))
    for (final (:step, place: _) in t.steps)
      if (step.spawned) '"${step.action}"'].join(', ')}}',
  '=============================================================================',
  '',
].join('\n');

/// The operators the engines define, over the variables of
/// `activation_base`.
String activationOps(Tables t) => [
  '----------------------------- MODULE activation_ops ---------------------------',
  '(* Printed from the definitions of RuntimeVars, ActivationTable,          *)',
  '(* SiteUnloadEngine and CookieIsolationEngine by lib/formal_model/main.dart. *)',
  '(* Not committed; edit the definitions.                                    *)',
  'EXTENDS activation_base',
  '',
  for (final d in t.ops) ...[d.tla, ''],
  '=============================================================================',
  '',
].join('\n');

/// What each table action reads and writes of the shared state, from its
/// declarations alone: the definitions it calls resolved through their
/// bodies, and the base's operators it calls named, whose reads
/// `formal/footprint.py` takes from their text and checks the sum against
/// the action's printed text. `fl` written is the flow's own row; read,
/// another flow's, which the last three columns narrow: the kinds of flow
/// the action's row can hold, the fields of it the action writes (`*` when
/// it ends the flow), and the fields of other rows it reads, by kind.
String activationFootprints(Tables t) {
  Reads resolve(Reads r, {required Set<ModelDef> seen}) => r.defs
      .difference(seen)
      .fold(
        r,
        (sum, d) => sum + resolve(definition(d).body.reads, seen: {...seen, d}),
      );
  String names(Iterable<String> all) => (all.toList()..sort()).join(' ');
  final all = _footprintsOf(t);
  final flows = flowsAt(all);
  // What an action needs: what each kind of flow reaching it needs, in
  // common, and its own step's; nothing reaches an action no flow does.
  Set<Need>? needed(Footprint f) {
    if (f.input) return f.needs;
    final byKind = flows[f.place];
    if (byKind == null || byKind.isEmpty) return null;
    return {
      ...byKind.values.reduce((a, b) => a.intersection(b)),
      ...f.needs,
    };
  }

  String needs(Iterable<Need> all) =>
      names([for (final (:of, :set) in all) set ? of.tla : '~${of.tla}']);
  return [
    '# action\treads\twrites\tbase operators called\tkinds\tfields written'
        '\trows read\tneeds',
    for (final f in all)
      if (resolve(f.reads, seen: const {}) case final r)
        [
          f.step.action,
          names([for (final v in r.vars) v.name]),
          names([for (final v in f.writes) v.name]),
          names([for (final b in r.base) b.tla]),
          names({
            for (final FlowKind k in f.input ? const [] : flows[f.place]?.keys ?? const [])
              k.name,
            for (final a in f.arms) ...[
              ?a.kind?.name,
              for (final r in a.spawns) r.kind.name,
            ],
          }),
          f.arms.any((a) => a.ends)
              ? '*'
              : names({
                  for (final a in f.arms)
                    for (final f in [...a.fields, for (final r in a.spawns) ...r.fields])
                      f.name,
                }),
          names({
            for (final (:kind, :field) in {
              ...r.rows,
              for (final b in r.base) ...b.rows,
            })
              '${kind.name}.${field.name}',
          }),
          if (needed(f) case final n?) needs(n) else 'unreached',
        ].join('\t'),
    for (final e in EnvAction.values)
      [
        e.coverage,
        names([for (final v in e.reads) v.name]),
        names([for (final v in e.writes) v.name]),
        '',
        '',
        '',
        '',
        needs(e.needs),
      ].join('\t'),
    '',
  ].join('\n');
}

/// What each base operator a table calls reads and writes, as [BaseOp]
/// declares it, for the footprint gate to hold to its definition.
String activationBaseOps() => [
  '# operator\treads\twrites',
  for (final b in BaseOp.values)
    [
      b.tla,
      ([for (final v in b.reads) v.name]..sort()).join(' '),
      ([for (final v in b.writes) v.name]..sort()).join(' '),
    ].join('\t'),
  '',
].join('\n');

/// What reaching each place takes, for each kind of flow whose row can
/// hold there: the model's constants every way there needs, read off every
/// table's arms by place name, as the model's `pc` names them. An input
/// lands on a row that holds no kind and needs nothing yet; an arm that
/// sets a kind gives it, one taken only for some kinds lets only those
/// through, every other carries the kind it found, and each adds what its
/// step and its branch need; one that ends the flow leaves nothing.
Map<String, Map<FlowKind, Set<Need>>> flowsAt(List<Footprint> all) {
  final at = <String, Map<FlowKind, Set<Need>>>{};
  var moved = true;
  void reach(String place, {required FlowKind kind, required Set<Need> need}) {
    final byKind = at.putIfAbsent(place, () => {});
    final was = byKind[kind];
    final now = was == null ? need : was.intersection(need);
    if (was == null || now.length != was.length) {
      byKind[kind] = now;
      moved = true;
    }
  }

  while (moved) {
    moved = false;
    for (final (:place, :input, :arms, :needs, step: _, reads: _, writes: _, guard: _)
        in all) {
      final Map<FlowKind?, Set<Need>> here = input
          ? {null: const {}}
          : {...?at[place]};
      for (final a in arms) {
        for (final MapEntry(key: k, value: got) in here.entries) {
          if (k != null && !(a.only?.contains(k) ?? true)) continue;
          // A flow the arm starts goes on from its input's places, whatever
          // the arm does to its own.
          for (final r in a.spawns) {
            for (final MapEntry(key: p, value: there) in r.next.entries) {
              reach(p, kind: r.kind, need: {...got, ...needs, ...a.needs, ...r.needs, ...there});
            }
          }
          final out = a.kind ?? k;
          if (a.ends || out == null) continue;
          for (final MapEntry(key: p, value: there) in a.next.entries) {
            reach(p, kind: out, need: {...got, ...needs, ...a.needs, ...there});
          }
        }
      }
    }
  }
  return at;
}

/// The kinds of flow a row can hold at each place ([flowsAt]).
Map<String, Set<FlowKind>> kindsAt(List<Footprint> all) => {
  for (final MapEntry(:key, :value) in flowsAt(all).entries)
    key: value.keys.toSet(),
};

/// The tables' actions and what each of their places needs.
String activationTables(Tables t) => [
  '---------------------------- MODULE activation_tables -------------------------',
  '(* Printed from the step tables of ActivationTable,                       *)',
  '(* SiteUnloadEngine and CookieIsolationEngine by lib/formal_model/main.dart. *)',
  '(* Not committed; edit the tables.                                         *)',
  'EXTENDS activation_ops',
  '',
  r'\* What a flow needs at each place it waits at, as the code asserts it',
  r"\* on the way in and after the place's call (Step.holds).",
  r'Inv_Places == \A f \in Flows :',
  for (final table in _all(t))
    for (final c in table.placesTla) '    /\\ $c',
  '',
  for (final table in _all(t))
    table.tla(
      variables: ModelVar.values,
      entered: _entered(t),
      starts: _starts(t),
    ),
  r"\* Every flow step of the tables, which activation.tla's FlowStep takes",
  r'\* whole.',
  'TableStep(f) ==',
  for (final s in _flowSteps(t)) '    \\/ ${s.action}(f)',
  '',
  r"\* Every input the tables start a flow with, which activation.tla's",
  r'\* InputStep takes whole.',
  'InputTableStep(f) ==',
  for (final s in _inputSteps(t)) '    \\/ ${s.action}(f)',
  '',
  '=============================================================================',
  '',
].join('\n');

List<Step<Object?, Enum>> _flowSteps(Tables t) => [
  for (final table in _all(t))
    for (final (:step, place: _) in table.steps)
      if (!step.input) step,
];

/// The inputs that start a flow on their own; a [Step.spawned] one prints
/// only in the action of the step that spawns it.
List<Step<Object?, Enum>> _inputSteps(Tables t) => [
  for (final table in _all(t))
    for (final (:step, place: _) in table.steps)
      if (step.input && !step.spawned) step,
];

/// The proof that each step of the tables keeps `IndInv`: a case per step,
/// by its action and the model's operators its acts call, so a new step is
/// a new case TLAPS proves or rejects with no hand edit.
/// `proofs/activation_turns.tla` takes `TableStep` whole.
String activationTablesProof(Tables t) => [
  '------------------------ MODULE activation_tables_proof -----------------------',
  '(* Printed from the step tables by lib/formal_model/main.dart.            *)',
  '(* Not committed; edit the tables instead.                                *)',
  'EXTENDS activation, TLAPS',
  '',
  _stepInd('TableStepInd', over: 'TableStep', steps: _flowSteps(t)),
  _stepInd('InputStepInd', over: 'InputTableStep', steps: _inputSteps(t)),
  '=============================================================================',
  '',
].join('\n');

/// The lemma that every step of [over] keeps `IndInv`, one case per step.
String _stepInd(
  String name, {
  required String over,
  required List<Step<Object?, Enum>> steps,
}) => [
  'LEMMA $name ==',
  '    ASSUME Good, IndInv, NEW f \\in Flows, $over(f)',
  "    PROVE  IndInv'",
  '  <1> USE DEF Good, IndInv, FlowsOK, Fresh, Inv_Places, NoFlow, Flows, Did',
  for (final (i, s) in steps.indexed) ...[
    '  <1>${i + 1}. CASE ${s.action}(f)',
    '    BY <1>${i + 1} DEF ${[s.action, if (s.input) 'Input', ..._operators(s)].join(', ')}',
  ],
  '  <1> QED',
  '    BY ${[for (var i = 1; i <= steps.length; i++) '<1>$i'].join(', ')}',
  '       DEF $over',
  '',
].join('\n');

/// For each invariant every step keeps as it stands ([Inv.inductive]): a
/// case per step, each closed by the step's definition, and the theorem
/// that it holds in every state beside `IndInv`, whose own preservation is
/// `proofs/activation_turns.tla`'s.
String activationInvariantsProof(Tables t) => [
  '--------------------- MODULE activation_invariants_proof ---------------------',
  '(* Printed from Inv and the step tables by lib/formal_model/main.dart.   *)',
  '(* Not committed; edit the declarations instead.                          *)',
  'EXTENDS activation_turns',
  '',
  for (final i in Inv.values)
    if (i.inductive) ...[
      _keeps(i, over: 'TableStep', steps: _flowSteps(t)),
      _keeps(i, over: 'InputTableStep', steps: _inputSteps(t)),
      _holds(i),
    ],
  '=============================================================================',
  '',
].join('\n');

/// The lemma that every step of [over] keeps [i], one case per step.
String _keeps(
  Inv i, {
  required String over,
  required List<Step<Object?, Enum>> steps,
}) => [
  'LEMMA ${i.tla}_$over ==',
  '    ASSUME Good, IndInv, ${i.tla}, NEW f \\in Flows, $over(f)',
  "    PROVE  ${i.tla}'",
  '  <1> USE DEF ${i.tla}, Flows',
  for (final (n, s) in steps.indexed) ...[
    '  <1>${n + 1}. CASE ${s.action}(f)',
    '    BY <1>${n + 1} DEF ${[s.action, if (s.input) 'Input', ..._operators(s)].join(', ')}',
  ],
  '  <1> QED',
  '    BY ${[for (var n = 1; n <= steps.length; n++) '<1>$n'].join(', ')}',
  '       DEF $over',
  '',
].join('\n');

/// [i] in every state: `Next`'s cases, the tables' by their lemmas and the
/// environment's ([EnvAction]) by their definitions.
String _holds(Inv i) {
  final cases = [
    (r'\E f \in Flows : InputTableStep(f)', '${i.tla}_InputTableStep'),
    (r'\E f \in Flows : FlowStep(f)', '${i.tla}_TableStep DEF FlowStep'),
    for (final e in EnvAction.values)
      (e.next, 'DEF ${e.op}${e == EnvAction.move || e == EnvAction.login ? ', Input' : ''}'),
    ('Done', 'DEF Done, vars'),
    ('UNCHANGED vars', 'DEF vars'),
  ];
  return [
    'THEOREM ${i.tla}_Holds == ASSUME Good PROVE Spec => []${i.tla}',
    '  <1>1. Init => ${i.tla}',
    '    BY DEF Init, WarmInit, ColdInit, ${i.tla}',
    "  <1>2. IndInv /\\ ${i.tla} /\\ [Next]_vars => ${i.tla}'",
    '    <2> SUFFICES ASSUME Good, IndInv, ${i.tla}, [Next]_vars',
    "                 PROVE  ${i.tla}'",
    '      OBVIOUS',
    '    <2> USE DEF ${i.tla}, Flows, site, sessions, turn, ghosts, tabVars,',
    '                blocking, archived, Did',
    for (final (n, (onCase, by)) in cases.indexed) ...[
      '    <2>${n + 1}. CASE $onCase',
      '      BY <2>${n + 1}${by.startsWith('DEF') ? ' $by' : ', $by'}',
    ],
    '    <2> QED',
    '      BY ${[for (var n = 1; n <= cases.length; n++) '<2>$n'].join(', ')}',
    '         DEF Next, InputStep',
    "  <1>3. Init => IndInv /\\ ${i.tla}",
    '    BY <1>1, InitInd',
    "  <1>4. IndInv /\\ ${i.tla} /\\ [Next]_vars => (IndInv /\\ ${i.tla})'",
    '    BY <1>2, StepInd',
    '  <1> QED',
    '    BY <1>3, <1>4, PTL DEF Spec',
    '',
  ].join('\n');
}

/// The model's operators [s]'s action calls: `Granted` for a step the jar's
/// turn grants, and the operator each of its acts opens with.
List<String> _operators(Step<Object?, Enum> s) => {
  if (s.granted) 'Granted',
  if (s.input || s.allArms.any((a) => a.then.any((e) => e is Spawn))) 'Starts',
  for (final arm in s.allArms)
    for (final e in arm.then)
      if (e is Act)
        if (RegExp(r'^[A-Z]\w*').firstMatch(e.tla) case final m?) m[0]!,
}.toList();

/// [ops] with the definition named as [def] replaced by it.
List<Def<Object?, Object?>> _withDef(
  List<Def<Object?, Object?>> ops, {
  required Def<Object?, Object?> def,
}) => [
  for (final d in ops)
    if (d.name == def.name) def else d,
];

/// [table] with [step]'s arms replaced by [arms].
StepTable<W, P> _withArms<W, P extends Enum>(
  StepTable<W, P> table, {
  required ActivationStep step,
  required Step<W, P> Function(Step<W, P> s) arms,
}) => StepTable(
  [for (final s in table.steps) s.place],
  ending: table.ending,
  awaited: table.awaited,
  at: (place) => switch (table.at(place)) {
    final Step<W, P> s when s.name == step => arms(s),
    final at => at,
  },
);

/// [table] with [step]'s branch for [outcome] taken out.
StepTable<W, P> _without<W, P extends Enum>(
  StepTable<W, P> table, {
  required ActivationStep step,
  required StepOutcome outcome,
}) => _withArms(
  table,
  step: step,
  arms: (s) => s.withArms(
    branches: [
      for (final b in s.branches)
        if (b.outcome != outcome) b,
    ],
    otherwise: s.otherwise,
  ),
);

/// `RouteFree` holding for any site: a background load that repoints a
/// loaded site's proxy, as the preload's guard did before it asked.
Def<bool, Object?> _routeFreeAlways() {
  final s = Bound<WebViewModel, Object?>('s');
  return Def(
    ModelDef.routeFree,
    params: [s],
    body: Expr.constant(true, tla: 'TRUE'),
  );
}

/// `Capture` keying the bytes it read by the webview's tab at the save,
/// after a rebind may have moved it (BUG-036 attempt 1).
Def<Map<WebViewModel, Map<TabId, TabId?>>, Object?> _captureAtReply() {
  final s = Bound<WebViewModel, Object?>('s');
  final t = Bound<TabId?, Object?>('t');
  final h = Bound<TabId?, Object?>('h');
  final built = TabVars.built<Object?>().at(s.it);
  final builtTab = Expr<TabId, Object?>(
    run: (c) => built.run(c)!,
    tla: built.tla,
    reads: built.reads,
  );
  final file = TabVars.file<Object?>().value;
  return Def(
    ModelDef.capture,
    params: [s, t, h],
    body: Expr.choose(
      when: built.neq(noTab()),
      then: file.exceptAt(s.it, at: builtTab, to: h.it),
      otherwise: file,
    ),
  );
}

/// `Shown` taking whatever back stack is queued, read for any tab.
Def<Map<WebViewModel, TabId?>, Object?> _shownTakeAny() {
  final s = Bound<WebViewModel, Object?>('s');
  final hist = TabVars.hist<Object?>().value;
  final queued = TabVars.queued<Object?>().value.at(s.it);
  final forTab = queued.part('t', get: (q) => q.t);
  final l = Bound<Iterable<WebViewModel>, Object?>('l');
  return Def(
    ModelDef.shown,
    params: [s, l],
    body: Expr.choose(
      when: TabVars.builds(s, l: l),
      then: hist.except(
        s.it,
        to: Expr.choose(
          when: forTab.neq(noTab()),
          then: queued.part('h', get: (q) => q.h),
          otherwise: TabVars.active<Object?>().at(s.it),
        ),
      ),
      otherwise: hist,
    ),
  );
}

/// The tables with those named replaced: a mistake names only what it
/// changes, and a new table fails to compile here until it is given one.
Tables _with({
  StepTable<ActivationFlow, ActivationPlace>? activation,
  StepTable<TabFlow, TabPlace>? tabInputs,
  StepTable<TabFlow, TabPlace>? tabFlow,
  StepTable<UnloadFlow, UnloadPlace>? unload,
  StepTable<UnloadWorld, UnloadPlace>? jar,
  StepTable<RestoreWorld, RestorePlace>? restore,
  StepTable<WakeFlow<Object>, WakePlace>? wake,
  StepTable<DnsFlow, DnsPlace>? dns,
  StepTable<CloseFlow, ClosePlace>? archive,
  StepTable<DeleteFlow, DeletePlace>? delete,
  List<Def<Object?, Object?>>? ops,
}) => (
  activation: activation ?? tables.activation,
  tabInputs: tabInputs ?? tables.tabInputs,
  tabFlow: tabFlow ?? tables.tabFlow,
  unload: unload ?? tables.unload,
  jar: jar ?? tables.jar,
  restore: restore ?? tables.restore,
  wake: wake ?? tables.wake,
  dns: dns ?? tables.dns,
  archive: archive ?? tables.archive,
  delete: delete ?? tables.delete,
  ops: ops ?? tables.ops,
);

/// Each mistake an engine once had, as the tables with it put back; the
/// check that catches it is the [Mutant]'s own.
Tables mutated(Mutant m) => switch (m) {
  // The refill goes on over a jar the refused nuke left as it was
  // (ISO-014).
  Mutant.nukeignored => _with(
    restore: _withArms(
      tables.restore,
      step: ActivationStep.restoreNukeReply,
      arms: (s) => s.withArms(
        refused: Refused<RestoreWorld, RestorePlace>(
          refusal: CookieIsolationEngine.jarRefusal,
          when: Expr.ofConstant(ModelConst.jarRefuses, run: (_) => true),
          then: [],
          next: to(RestorePlace.rLoad),
        ),
      ),
    ),
  ),
  // The restore takes in only the sites it saves, so a loaded incognito
  // site's session goes with the emptied jar (INC-001), as before the fix.
  Mutant.incognitonuked => _with(
    restore: _withArms(
      tables.restore,
      step: ActivationStep.grantRestore,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            s.otherwise.then.first,
            const Field<List<WebViewModel>, RestoreWorld>(FlowField.ls).becomes(
              Expr.op(
                r'loaded \ Incognito',
                run: (_) => const [],
                reads: const Reads(vars: {ModelVar.loaded}),
              ),
            ),
          ],
          next: s.otherwise.next,
        ),
      ),
    ),
  ),
  // A close deletes its containers without waiting for the frame that
  // unmounts its sites' webviews, and a container a mounted webview still
  // binds is not deleted (LIR-023).
  Mutant.closenoframe => _with(
    archive: _withArms(
      tables.archive,
      step: ActivationStep.closeFrameReply,
      arms: (s) => Step(
        s.name,
        holds: s.holds,
        call: Call(run: (_) async {}, writes: const []),
        branches: s.branches,
        otherwise: s.otherwise,
      ),
    ),
  ),
  // A rebind that reroutes the slot takes it out of the loaded sites and
  // starts no activation, as the tab table printed it before its spawn
  // (LIR-024, BUG-037 attempt 13).
  Mutant.noreopen => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.tabRebind,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: b.when,
              pick: b.pick,
              site: b.site,
              tab: b.tab,
              then: [
                for (final e in b.then)
                  if (e is! Spawn) e,
              ],
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A delete deletes its site's container without waiting for the frame
  // that unmounts its webview (BUG-038).
  Mutant.deletenoframe => _with(
    delete: _withArms(
      tables.delete,
      step: ActivationStep.deleteFrameReply,
      arms: (s) => Step(
        s.name,
        holds: s.holds,
        call: Call(run: (_) async {}, writes: const []),
        branches: s.branches,
        otherwise: s.otherwise,
      ),
    ),
  ),
  // A tab switch moves the pointer at its capture's reply, before the nav
  // read (BUG-036 attempt 1): an await then sees a webview built for one
  // tab while the site names another.
  Mutant.pointerearly => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.tabCaptureReply,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            ...s.otherwise.then,
            Act<TabFlow>(
              writes: {ModelVar.active},
              tla: 'active\' = [active EXCEPT ![fl[f].site] = fl[f].tab]',
              run: (_) {},
              reads: const Reads(vars: {ModelVar.active}),
            ),
          ],
          next: s.otherwise.next,
        ),
      ),
    ),
  ),
  // A capture keys the bytes it read by the webview's tab at its reply, not
  // as it started (BUG-036 attempt 1's second shape): a rebind landing
  // between stores the outgoing tab's history under the incoming one.
  Mutant.captureatreply => _with(
    ops: _withDef(tables.ops, def: _captureAtReply()),
  ),
  // A preload loads a site whose proxy route a loaded site in its scope
  // does not run (PROXY-008): one site's traffic leaves through the
  // other's proxy.
  Mutant.preloadmismatch => _with(
    ops: _withDef(tables.ops, def: _routeFreeAlways()),
  ),
  // The build takes whatever back stack is queued, read for any tab.
  Mutant.takeany => _with(
    ops: _withDef(tables.ops, def: _shownTakeAny()),
  ),
  // An unload captures a site no longer loaded (BUG-032): no wait asks.
  Mutant.recapture => _with(
    ops: _withDef(
      tables.ops,
      def: Def<bool, UnloadFlow>.ofFlow(
        ModelDef.gone,
        body: Expr.constant(false, tla: 'FALSE'),
      ),
    ),
  ),
  // A superseded switch's conflict unload still disposes, taking the site a
  // newer tap opens (BUG-033).
  Mutant.staleplan => _with(
    ops: _withDef(
      tables.ops,
      def: SiteUnloadEngine.spareOf(stale: false, retry: true),
    ),
  ),
  // An unload picked by priority does not ask again before it disposes
  // (BUG-033).
  Mutant.noretry => _with(
    ops: _withDef(
      tables.ops,
      def: SiteUnloadEngine.spareOf(stale: true, retry: false),
    ),
  ),
  // A superseded switch leaves the screen on a site its residency unloaded
  // (BUG-029, LAZY-007).
  Mutant.nohome => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.exit,
      arms: (s) => s.withArms(branches: const []),
    ),
  ),
  // The marker is cleared by any activation with its target, as a double
  // tap's first did (CONT-003).
  Mutant.markerbytarget => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.exit,
      arms: (s) {
        final byTarget = Act<ActivationFlow>(
          writes: {ModelVar.marker},
          tla:
              'marker\' = IF fl[f].kind = "tap" /\\ marker.t = fl[f].site '
              'THEN NoMarker ELSE marker',
          run: (_) {},
          reads: const Reads(vars: {ModelVar.marker}),
        );
        List<Effect<ActivationFlow>> swap(List<Effect<ActivationFlow>> then) =>
            [
              for (final e in then)
                if (e case Act(:final writes) when writes.contains(ModelVar.marker))
                  byTarget
                else
                  e,
            ];
        return s.withArms(
          branches: [
            for (final b in s.branches)
              Branch(
                b.outcome,
                when: b.when,
                pick: b.pick,
                site: b.site,
                then: swap(b.then),
                next: b.next,
              ),
          ],
          otherwise: Otherwise(
            s.otherwise.outcome,
            pick: s.otherwise.pick,
            site: s.otherwise.site,
            then: swap(s.otherwise.then),
            next: s.otherwise.next,
          ),
        );
      },
    ),
  ),
  // A preload marks its site loaded without restoring its session, over
  // what the last session left in the jar.
  // The frame after a preload's commit sees the loaded sites as the commit
  // found them, without the one it loads, so it binds no tab.
  Mutant.preloadunbound => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.commit,
      arms: (s) => s.withArms(
        branches: [
          s.branches.first,
          for (final b in s.branches.skip(1))
            Branch(
              b.outcome,
              when: b.when,
              pick: b.pick,
              site: b.site,
              tab: b.tab,
              then: [
                for (final e in b.then)
                  if (e is Act<ActivationFlow> &&
                      e.writes.contains(ModelVar.built))
                    TabVars.framed(
                      const Field<WebViewModel, ActivationFlow>(
                        FlowField.site,
                      ).value,
                      loaded: Mutable<Iterable<WebViewModel>, ActivationFlow>
                          .remote(ModelVar.loaded)
                          .value,
                    )
                  else
                    e,
              ],
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  Mutant.preloadbare => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.preloadNavReply,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: const [],
          next: to(ActivationPlace.commit),
        ),
      ),
    ),
  ),
  // The capture, not the dispose, makes the site "saved" (BUG-033).
  // A nested open moves the proxy without asking again once it has, the
  // shape before BUG-037 attempt 6: a site that loaded during the move
  // stays beside the screen.
  Mutant.nestedonce => _with(
    activation: _without(
      tables.activation,
      step: ActivationStep.nestedApplyReply,
      outcome: StepOutcome.unload,
    ),
  ),
  // A preload commits without asking again, beside a nested screen that
  // went up since its input.
  Mutant.preloadunchecked => _with(
    activation: _without(
      tables.activation,
      step: ActivationStep.commit,
      outcome: StepOutcome.bail,
    ),
  ),
  // A wake's check that asks only whether the app came back, not the
  // rule, the shape before BUG-037 attempt 8: the wake took its route from
  // the notification sites alone and moved it under the site left on
  // screen.
  Mutant.wakeunchecked => _with(
    wake: _withArms(
      tables.wake,
      step: ActivationStep.wakeAsk,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: Var<bool, WakeFlow<Object>>(
                ModelVar.fore,
                read: (w) => w.host.vars.fore.value,
              ).value,
              pick: b.pick,
              site: b.site,
              then: b.then,
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A webspace switch whose input supersedes no activation in flight, as
  // before BUG-033 attempt 5: a tap begun on the list before it opens a
  // site the switch stopped showing.
  Mutant.spaceold => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.spaceSwitch,
      arms: (s) => s.withArms(
        otherwise: ActivationTable.spaceInputOf(
          supersedes: false,
        ).otherwise,
      ),
    ),
  ),
  // A wake's check that waits out an activation but not a nested open in
  // flight: the open's pop brings the site on screen back on its own route.
  Mutant.wakebesidenested => _with(
    wake: _withArms(
      tables.wake,
      step: ActivationStep.wakeAsk,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: Expr.op(
                '(fore \\/ (marker # NoMarker)) \\/ ~(RouteFree(s))',
                run: (_) => false,
                reads: const Reads(
                  vars: {ModelVar.fore, ModelVar.marker},
                  defs: {ModelDef.routeFree},
                ),
              ),
              pick: b.pick,
              site: b.site,
              then: b.then,
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A wake's check that asks the rule over what runs but not whether an
  // activation is in flight: a tap whose plan ran before the check then
  // commits beside it on another route.
  Mutant.wakebesidetap => _with(
    wake: _withArms(
      tables.wake,
      step: ActivationStep.wakeAsk,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: Expr.op(
                'fore \\/ ~(RouteFree(s))',
                run: (_) => false, reads: const Reads(vars: {ModelVar.fore},
                defs: {ModelDef.routeFree}),
              ),
              pick: b.pick,
              site: b.site,
              then: b.then,
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A download's fold that tells the views their level before the new
  // app-wide level is in force, the shape c7376c8b fixed: listeners were
  // notified as the partition landed and read the level it replaced.
  Mutant.foldbeforelevel => _with(
    dns: _withArms(
      tables.dns,
      step: ActivationStep.dnsFolded,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            modelOnly(
              "dns' = [lvl |-> IF fl[f].appWide THEN fl[f].lvl ELSE dns.lvl, "
              'levels |-> dns.levels \\cup {fl[f].lvl}] /\\ '
              "told' = [s \\in Sites |-> IF told[s] = -1 THEN -1 ELSE "
              'ResolveLevel(SiteLevel[s], dns.lvl, '
              'dns.levels \\cup {fl[f].lvl})]',
              writes: {ModelVar.dns, ModelVar.told},
              reads: const Reads(vars: {ModelVar.dns}),
            ),
          ],
          next: s.otherwise.next,
        ),
      ),
    ),
  ),
  Mutant.tierearly => _with(
    unload: _withArms(
      tables.unload,
      step: ActivationStep.unloadCaptured,
      arms: (s) {
        final early = Act<UnloadFlow>(
          writes: {ModelVar.tier},
          tla: 'tier\' = [tier EXCEPT ![fl[f].victim] = "saved"]',
          run: (_) {},
          reads: const Reads(vars: {ModelVar.tier}),
        );
        return s.withArms(
          branches: [
            for (final b in s.branches)
              if (b.outcome == StepOutcome.spared)
                Branch(
                  b.outcome,
                  when: b.when,
                  pick: b.pick,
                  site: b.site,
                  then: [...b.then, early],
                  next: b.next,
                )
              else
                b,
          ],
          otherwise: Otherwise(
            s.otherwise.outcome,
            pick: s.otherwise.pick,
            site: s.otherwise.site,
            then: [...s.otherwise.then, early],
            next: s.otherwise.next,
          ),
        );
      },
    ),
  ),
};

/// Every engine's declared model: its steps, where each waits and what it
/// needs there.
Map<String, Object?> declaredModels() => {
  'activation': {
    'steps': [
      for (final s in ActivationStep.values)
        {
          'action': s.action,
          'outcomes': [for (final o in s.outcomes) o.tla],
          'calls': [for (final c in s.calls) c.label],
        },
    ],
    'tables': {
      'activation': _places(tables.activation),
      'unload': _places(tables.unload),
      'jar': _places(tables.jar),
      'restore': _places(tables.restore),
    },
  },
};

List<Map<String, Object?>> _places<W, P extends Enum>(StepTable<W, P> t) => [
  for (final (:place, :step) in t.steps)
    {
      'place': place.name,
      'action': step.action,
      'granted': step.granted,
      'input': step.input,
      'holds': step.holds?.tla,
      'next': {for (final a in step.allArms) a.outcome.tla: a.next.tla},
    },
];
