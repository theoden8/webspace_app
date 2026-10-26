// What the code declares for formal/, printed: the TLA+ modules the models
// extend, the planted mistakes TLC must catch, and every engine's declared
// model as JSON for the tools that are not TLA+. main.dart writes them; the
// files are derivatives, written under build/formal/ and never committed.
import 'dart:convert';

import 'package:webspace/formal_model/checks.dart';
import 'package:webspace/formal_model/lean_footprints.dart';
import 'package:webspace/formal_model/types_proof.dart';
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
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/settings/proxy.dart' show ProxyRouteKey;
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_table.dart';

part 'mutants.dart';

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
  StepTable<WakeFlow<WebViewModel>, WakePlace> wake,
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
  ModelDef.pages => RuntimeVars.pagesOf<Object>(),
  ModelDef.running => RuntimeVars.runningSites<Object>(),
  ModelDef.runsAs => TabVars.runsAs<Object?>(),
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
  ModelDef.tabBusy => TabTable.tabBusy,
  ModelDef.reopens => TabTable.reopens,
  ModelDef.movesRule => TabTable.movesRule,
  ModelDef.capture => TabVars.capture<Object?>(),
  ModelDef.bound => TabVars.bound<Object?>(),
  ModelDef.takes => takesOf<Object?>(),
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
  tabInputs: TabTable.tabInputs,
  tabFlow: TabTable.tabFlow,
  unload: SiteUnloadEngine.unloadFlow,
  jar: CookieIsolationEngine.unloadSteps,
  restore: CookieIsolationEngine.restoreSteps,
  wake: wakeTable<WebViewModel>(),
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

/// The modules `formal/` writes by hand that the printed ones extend, from
/// the repository's root.
const handWrittenModules = ['formal/activation_base.tla', 'formal/activation.tla'];

/// Everything there is to print, in one list: a new engine's model is a new
/// entry here. [handWritten] is the text of the modules `formal/` writes by
/// hand that the printed ones extend, whose definitions a proof opens.
List<PrintedFile> printedModels({required List<String> handWritten}) => [
  (path: 'activation_vars.tla', text: activationVars()),
  (path: 'activation_steps.tla', text: activationSteps()),
  (path: 'activation_ops.tla', text: activationOps(tables)),
  (path: 'activation_tables.tla', text: activationTables(tables)),
  (path: 'activation_tables_proof.tla', text: activationTablesProof(tables)),
  (path: '$_tablesFacts.tla', text: activationTablesFacts()),
  ...activationTablesParts(tables),
  (
    path: 'activation_invariants_proof.tla',
    text: activationInvariantsProof(tables),
  ),
  ...activationTypesProofs(
    tables: {
      for (final m in ModelTable.values)
        m.name: _table(tables, of: m)
            .flSteps(entered: _entered(tables), starts: _starts(tables)),
    },
    definitions: tlaDefinitions([
      activationVars(),
      activationOps(tables),
      ...handWritten,
    ]),
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
    (
      path: 'mutants/${m.name}/activation_ops.tla',
      text: activationOps(mutated(m)),
    ),
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
      if (f.writes
          .difference({ModelVar.fl, ModelVar.last, ModelVar.inputs})
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
      armed: const {},
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
              for (final a in f.arms) ...[
                ?a.kind,
                for (final r in a.spawns) r.kind,
              ],
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
            armed: {
              for (final v in f.writes)
                if ([
                  for (final a in f.arms)
                    if (a.writes.contains(v)) a.needs,
                ] case final by when by.length < f.arms.length)
                  v: by.reduce((x, y) => x.intersection(y)),
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
  ..._types(t),
  '=============================================================================',
  '',
].join('\n');

/// What the model's variables hold, from each [ModelVar]'s type and each
/// [FlowField]'s range: `TypeOK`, which every world checks, over the kinds
/// a flow can be and the places of every table.
List<String> _types(Tables t) {
  final tables = <StepTable<Object?, Enum>>[
    t.activation,
    t.tabInputs,
    t.tabFlow,
    t.unload,
    t.jar,
    t.restore,
    t.wake,
    t.dns,
    t.archive,
    t.delete,
  ];
  final places = {
    FlowField.pc.none,
    for (final table in tables)
      for (final p in table.places) '"${p.name}"',
  };
  return [
    'FlowKinds == {${[FlowField.kind.none, for (final k in FlowKind.values) '"${k.name}"'].join(', ')}}',
    '',
    'Places == {${places.join(', ')}}',
    '',
    'FlowRecord == [${[for (final f in FlowField.values) '${f.name} : ${f.range}'].join(', ')}]',
    '',
    'TypeOK ==',
    for (final v in ModelVar.values) '    /\\ ${v.type}',
    '',
  ];
}

/// What each action may read of the shared state, by its printed
/// footprint: the variables it reads and writes, those of the definitions
/// it calls, resolved, and those of the base's operators. The walks hold
/// what each step read as it ran ([StepReads]) to it.
Map<ActivationStep, Set<ModelVar>> footprintReads(Tables t) {
  final out = <ActivationStep, Set<ModelVar>>{};
  for (final f in _footprintsOf(t)) {
    final r = _resolved(f.reads, seen: const {});
    (out[f.step] ??= {}).addAll({
      ...r.vars,
      ...f.writes,
      for (final b in r.base) ...b.reads,
    });
  }
  return out;
}

/// What the notes of each step read ([Note.reads]): the code's alone, for
/// what the model does not hold, so it stays out of the printed footprint
/// and the walks' read gate holds each note to it.
Map<ActivationStep, Set<ModelVar>> noteReads(Tables t) {
  final out = <ActivationStep, Set<ModelVar>>{};
  for (final table in _all(t)) {
    for (final MapEntry(key: step, value: reads) in table.noteReads.entries) {
      final r = _resolved(reads, seen: const {});
      (out[step] ??= {}).addAll({
        ...r.vars,
        for (final b in r.base) ...b.reads,
      });
    }
  }
  return out;
}

/// What each table action reads and writes of the shared state, from its
/// declarations alone: the definitions it calls resolved through their
/// bodies, and the base's operators it calls named, whose reads
/// `formal/footprint.py` takes from their text and checks the sum against
/// the action's printed text. `fl` written is the flow's own row; read,
/// another flow's, which the last three columns narrow: the kinds of flow
/// the action's row can hold, the fields of it the action writes (`*` when
/// it ends the flow), and the fields of other rows it reads, by kind.
String activationFootprints(Tables t) {
  String names(Iterable<String> all) => (all.toList()..sort()).join(' ');
  final all = _footprintsOf(t);
  final flows = flowsAt(all);
  // What an action needs: what each kind of flow reaching it needs, in
  // common, and its own step's; nothing reaches an action no flow does.
  Set<Need>? needed(Footprint f) {
    if (f.input) return f.needs;
    final byKind = flows[f.place];
    if (byKind == null || byKind.isEmpty) return null;
    return {...byKind.values.reduce((a, b) => a.intersection(b)), ...f.needs};
  }

  String needs(Iterable<Need> all) =>
      names([for (final (:of, :set) in all) set ? of.tla : '~${of.tla}']);
  return [
    '# action\treads\twrites\tbase operators called\tkinds\tfields written'
        '\trows read\tneeds',
    for (final f in all)
      if (_resolved(f.reads, seen: const {}) case final r)
        [
          f.step.action,
          names([for (final v in r.vars) v.name]),
          names([for (final v in f.writes) v.name]),
          names([for (final b in r.base) b.tla]),
          names({
            for (final FlowKind k
                in f.input ? const [] : flows[f.place]?.keys ?? const [])
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
                    for (final f in [
                      ...a.fields,
                      for (final r in a.spawns) ...r.fields,
                    ])
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
    for (final (
          :place,
          :input,
          :arms,
          :needs,
          step: _,
          reads: _,
          writes: _,
          guard: _,
        )
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
              reach(
                p,
                kind: r.kind,
                need: {...got, ...needs, ...a.needs, ...r.needs, ...there},
              );
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
String activationTables(
  Tables t, {
  TlaGuardOrder guardOrder = TlaGuardOrder.preferred,
}) => [
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
      guardOrder: guardOrder,
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
/// a new case TLAPS proves or rejects with no hand edit. A flow step's case
/// cites its lemma in [activationTablesParts], which tlapm takes as given
/// here and proves in that module. `proofs/activation_turns.tla` takes
/// `TableStep` whole.
String activationTablesProof(Tables t) => [
  '------------------------ MODULE activation_tables_proof -----------------------',
  '(* Printed from the step tables by lib/formal_model/main.dart.            *)',
  '(* Not committed; edit the tables instead.                                *)',
  'EXTENDS ${[for (final (path: p, text: _) in activationTablesParts(t)) p.replaceAll('.tla', ''), 'TLAPS'].join(', ')}',
  '',
  _stepInd(
    'TableStepInd',
    over: 'TableStep',
    steps: _flowSteps(t),
    byLemma: true,
  ),
  _stepInd(
    'InputStepInd',
    over: 'InputTableStep',
    steps: _inputSteps(t),
    byLemma: false,
  ),
  '=============================================================================',
  '',
].join('\n');

const _tablesFacts = 'activation_tables_facts_proof';

/// What a step's case reads of `NoFlow`: its row's place, after an update
/// that keeps the record's fields, a reset to `NoFlow` or an input's start
/// of the next row. Proved once here, where the record is unfolded, so no
/// case unfolds it: preparing a case that opens `NoFlow`'s fields for SMT
/// took three to four times as long as the case citing this lemma, and the
/// solver none of it.
String activationTablesFacts() => [
  '---------------------- MODULE $_tablesFacts ----------------------',
  '(* Printed from the step tables by lib/formal_model/main.dart.            *)',
  '(* Not committed; edit the tables instead.                                *)',
  'EXTENDS activation, TLAPS',
  '',
  'LEMMA NoFlowPc == "${FlowField.pc.name}" \\in DOMAIN NoFlow /\\ NoFlow.pc = "done"',
  '  BY DEF NoFlow',
  '',
  '=============================================================================',
  '',
].join('\n');

/// The flow steps' lemmas, [_partSize] steps a module: tlapm prepares a
/// module's obligations on one thread, so modules are what proves in
/// parallel (`proofs/check_proofs.sh`).
List<PrintedFile> activationTablesParts(Tables t) {
  final steps = _flowSteps(t);
  final arms = _alternatives(t);
  final footprints = {for (final f in _footprintsOf(t)) f.step: f};
  final held = {
    for (final table in _all(t))
      for (final (:place, :step) in table.steps)
        if (step.holds != null) place.name,
  };
  return [
    for (var i = 0; i < steps.length; i += _partSize)
      (
        path: 'activation_tables_${i ~/ _partSize + 1}_proof.tla',
        text: [
          '---------------------- MODULE activation_tables_${i ~/ _partSize + 1}_proof ----------------------',
          '(* Printed from the step tables by lib/formal_model/main.dart.            *)',
          '(* Not committed; edit the tables instead.                                *)',
          'EXTENDS $_tablesFacts',
          '',
          for (final s in steps.skip(i).take(_partSize))
            _armsInd(
              s,
              arms: arms[s.name]!,
              places: [for (final table in _all(t)) ...table.placesTla],
              footprint: footprints[s.name]!,
              held: held,
            ),
          '=============================================================================',
          '',
        ].join('\n'),
      ),
  ];
}

const _partSize = 8;

/// Every step's action as its alternatives ([TablePrint.alternatives]).
Map<ActivationStep, List<StepAlternative>> _alternatives(Tables t) => {
  for (final table in _all(t))
    ...table.alternatives(
      variables: ModelVar.values,
      entered: _entered(t),
      starts: _starts(t),
    ),
};

/// The lemma that every step of [over] keeps `IndInv`, one case per step:
/// by the step's lemma ([_armsInd]) when [byLemma], else by its action.
/// A lemma's case keeps `IndInv` folded: the lemma states it whole, and
/// unfolding it there only gives the backends more to match.
String _stepInd(
  String name, {
  required String over,
  required List<Step<Object?, Enum>> steps,
  required bool byLemma,
}) => [
  'LEMMA $name ==',
  '    ASSUME Good, IndInv, NEW f \\in Flows, $over(f)',
  "    PROVE  IndInv'",
  if (!byLemma)
    '  <1> USE NoFlowPc DEF Good, IndInv, FlowsOK, Fresh, Inv_Places, Flows, Did',
  for (final (i, s) in steps.indexed) ...[
    '  <1>${i + 1}. CASE ${s.action}(f)',
    if (byLemma)
      '    BY <1>${i + 1}, ${s.action}_Ind'
    else
      '    BY <1>${i + 1} DEF ${[s.action, if (s.input) 'Input', ..._operators(s)].join(', ')}',
  ],
  '  <1> QED',
  '    BY ${[for (var i = 1; i <= steps.length; i++) '<1>$i'].join(', ')}',
  '       DEF $over',
  '',
].join('\n');

/// The lemma that flow step [s] keeps `IndInv`, an arm at a time: its
/// action is unfolded once, into its alternatives [arms], and each is
/// closed by itself, since one obligation over the whole action can
/// outgrow the backends (a step of several arms that spawns). The flow at
/// the step's place is one an input started, so it is numbered within
/// `inputs` (`Fresh`), which an arm that keeps the flow, or starts the
/// next, needs and finds less easily: every arm starts at the step's place,
/// so that is proved once, before the split, as is its distinction from
/// the next input's row. Only an arm unfolds `IndInv`:
/// the split and the QED close as they stand, and unfolded they time out.
String _armsInd(
  Step<Object?, Enum> s, {
  required List<StepAlternative> arms,
  required List<String> places,
  required Footprint footprint,
  required Set<String> held,
}) {
  final spawning = s.allArms.any((a) => a.then.any((e) => e is Spawn));
  return [
    'LEMMA ${s.action}_Ind ==',
    '    ASSUME Good, IndInv, NEW f \\in Flows, ${s.action}(f)',
    "    PROVE  IndInv'",
    if (spawning) ...['  <1>0. Good /\\ IndInv', '    OBVIOUS'],
    '  <1>1. ${[for (final a in arms) '(${a.tla})'].join(' \\/ ')}',
    '    BY DEF ${s.action}',
    if (spawning) '  <1> HIDE ${s.action}(f)',
    '  <1>2. fl[f].pc # "done"',
    '    BY <1>1',
    '  <1>3. ${spawning ? 'f \\in Nat /\\ ' : ''}f <= inputs${spawning ? ' /\\ f # inputs + 1' : ''}',
    '    BY <1>2 DEF Good, IndInv, Fresh, Flows',
    for (final (n, a) in arms.indexed) ...[
      '  <1>${n + 4}. CASE ${a.tla}',
      if (a.spawns)
        ..._rowsInd(
          s,
          arm: n + 4,
          places: places,
          footprint: footprint,
          held: held,
        )
      else
        '    BY <1>${n + 4}, <1>3, NoFlowPc DEF ${['Good', 'IndInv', 'FlowsOK', 'Fresh', 'Inv_Places', 'Flows', 'Did', ..._operators(s)].join(', ')}',
    ],
    '  <1> QED',
    '    BY ${['<1>1', for (var n = 4; n < arms.length + 4; n++) '<1>$n'].join(', ')}',
    '',
  ].join('\n');
}

/// A spawning arm can update both its own row and the next input's, with
/// several fields in each. Split on the row before asking the backends to
/// simplify those updates: a single obligation over every row and every
/// conjunct of IndInv can exhaust Zenon's memory. Prove the next places
/// from the action first, with only the row's field and index facts; a
/// place outside every held place then needs no record updates unfolded.
List<String> _rowsInd(
  Step<Object?, Enum> s, {
  required int arm,
  required List<String> places,
  required Footprint footprint,
  required Set<String> held,
}) {
  final next = {
    'done',
    for (final a in footprint.arms) ...[
      ...a.next.keys,
      for (final spawn in a.spawns) ...spawn.next.keys,
    ],
  };
  final fields =
      '{${[for (final f in FlowField.values) '"${f.name}"'].join(', ')}}';
  final frame = [
    for (final v in ModelVar.values)
      if (!footprint.writes.contains(v)) v.name,
  ];
  final changesHeld = footprint.writes.any(
    (v) =>
        v != ModelVar.fl &&
        places.any((p) => RegExp('\\b${v.name}\\b').hasMatch(p)),
  );
  final claims = [
    "DOMAIN fl'[g] = DOMAIN NoFlow",
    "g > inputs' => fl'[g].pc = \"done\"",
    for (final p in places) "(${p.replaceAll(RegExp(r'\bf\b'), 'g')})'",
  ];
  final before = [
    'g \\in Nat /\\ inputs \\in Nat',
    'g \\in DOMAIN fl /\\ DOMAIN fl[g] = DOMAIN NoFlow',
    '$fields \\subseteq DOMAIN fl[g]',
    'g > inputs => fl[g].pc = "done"',
    'NoFlow.pc = "done"',
    for (final p in places) p.replaceAll(RegExp(r'\bf\b'), 'g'),
  ];
  return [
    '    <2>0. Starts',
    '      BY ONLY <1>$arm',
    "    <2>1. inputs' \\in Nat /\\ inputs <= inputs' /\\ f <= inputs'",
    '      BY ONLY <1>0, <2>0, <1>3 DEF IndInv, Starts',
    "    <2>2. DOMAIN fl' = Flows",
    '      BY ONLY <1>0, <1>$arm DEF IndInv, FlowsOK, Flows',
    '    <2>4. UNCHANGED << ${frame.join(', ')} >>',
    '      BY ONLY <1>$arm',
    '    <2>5. DOMAIN NoFlow = $fields /\\ NoFlow.pc = "done"',
    '      BY ONLY DEF NoFlow',
    '    <2>3. \\A g \\in Flows :',
    for (final c in claims) '        /\\ ($c)',
    '      <3> SUFFICES ASSUME NEW g \\in Flows',
    '                   PROVE',
    for (final c in claims) '                     /\\ ($c)',
    '        OBVIOUS',
    '      <3>4. g \\in Flows',
    '        OBVIOUS',
    '      <3>0.',
    for (final b in before) '          /\\ ($b)',
    '        BY ONLY <1>0, <3>4, <2>5 DEF IndInv, FlowsOK, Fresh, Inv_Places, Flows',
    for (final (n, c) in [
      'g = f',
      'g = inputs + 1',
      'g # f /\\ g # inputs + 1',
    ].indexed) ...[
      '      <3>${n + 1}. CASE $c',
      if (n == 2) ...[
        '        <4>0. fl\'[g] = fl[g]',
        '          BY ONLY <3>0, <3>${n + 1}, <1>$arm',
      ],
      '        <4>1. ${claims[0]}',
      if (n == 2)
        '          BY ONLY <3>0, <4>0'
      else
        '          BY ONLY <3>0, <3>${n + 1}, <1>$arm, <1>3',
      '        <4>2. ${claims[1]}',
      if (n == 0)
        '          BY ONLY <3>0, <3>1, <2>1'
      else if (n == 1)
        '          BY ONLY <3>0, <3>2, <2>0 DEF Starts'
      else
        '          BY ONLY <3>0, <4>0, <2>1',
      if (n < 2) ...[
        '        <4>4. fl\'[g].pc \\in {${[for (final p in next) '"$p"'].join(', ')}}',
        '          BY ONLY <3>0, <3>${n + 1}, <1>$arm, <1>3',
        '        <4>5.',
        for (final p in claims.skip(2)) '            /\\ ($p)',
        if (next.intersection(held).isEmpty)
          '          BY ONLY <4>4'
        else
          '          BY ONLY <4>4, <3>0, <3>${n + 1}, <1>$arm, <1>0, <1>3 DEF ${['Good', 'Did', ..._operators(s)].join(', ')}',
      ] else ...[
        '        <4>5.',
        for (final p in claims.skip(2)) '            /\\ ($p)',
        if (changesHeld)
          '          BY ONLY <4>0, <3>0, <1>$arm, <1>0 DEF ${['Good', 'Did', ..._operators(s)].join(', ')}'
        else
          '          BY ONLY <4>0, <3>0, <2>4',
      ],
      '        <4> QED',
      '          BY <4>1, <4>2, <4>5',
    ],
    '      <3> QED',
    '        BY <3>1, <3>2, <3>3',
    '    <2> QED',
    '      BY <2>1, <2>2, <2>3 DEF IndInv, FlowsOK, Fresh, Inv_Places',
  ];
}

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
      (
        e.next,
        'DEF ${e.op}${e == EnvAction.move || e == EnvAction.login ? ', Input' : ''}',
      ),
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
