// The activation model's footprints as Lean data for formal/lean/: every
// action's declared reads and writes, what each way to it needs of the
// constants, and each holding world's constants, inputs and invariants.
// Footprints.everyInvariantLicensed decides over them, by `decide`, that
// every invariant is checked in some world that takes its whole cone.

import 'package:webspace/formal_model/checks.dart';
import 'package:webspace/formal_model/worlds.dart';
import 'package:webspace/services/model_names.dart';

/// A world TLC checks the invariants in, as the Lean check reads it.
typedef LeanWorld = ({String cfg, WorldSpec spec, List<Inv> invariants});

/// What the footprint gate leaves out of every declaration and the cone
/// theorem needs back: `Calm` and `Idle` read every flow's row, `Input`
/// reads and writes `inputs`, `Did` writes `last`, a witness reads and
/// writes `seen`. Each action is taken to read and write all four, which
/// over-approximates and so keeps the theorem's premise.
const _scheduler = [ModelVar.fl, ModelVar.inputs, ModelVar.last, ModelVar.seen];

String _cap(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

String _list(Iterable<String> items) => '[${items.join(', ')}]';

String footprintsLean({
  required List<ComposedAction> actions,
  required Set<String> inputs,
  required List<LeanWorld> worlds,
}) {
  final envNames = {for (final e in EnvAction.values) e.coverage: _cap(e.name)};
  String act(String name) => envNames[name] ?? name;
  final names = [for (final a in actions) act(a.name)];
  final ident = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  assert(
    names.every(ident.hasMatch) && names.toSet().length == names.length,
    'every action is one Lean identifier',
  );
  assert(
    worlds.every((w) => ident.hasMatch(w.cfg)),
    'every world is one Lean identifier',
  );
  String vars(Iterable<ModelVar> vs) => _list([
    for (final v in ModelVar.values)
      if (vs.contains(v)) '.${v.name}',
  ]);
  String need(Need n) => '(.${n.of.tla}, ${n.set})';
  String inductive(String name, {required Iterable<String> ctors}) => [
    'inductive $name',
    for (final c in ctors) '  | $c',
    '  deriving DecidableEq, Repr',
    '',
    'def $name.all : List $name := ${_list([for (final c in ctors) '.$c'])}',
  ].join('\n');
  return [
    '-- Printed from the step tables and lib/formal_model/checks.dart by',
    '-- lib/formal_model/main.dart. Not committed; edit the declarations.',
    'import Footprint',
    '',
    'namespace Activation',
    'open Footprint',
    '',
    '/-- The actions of `formal/activation.tla`, the environment\'s among them. -/',
    inductive('Act', ctors: names),
    '',
    '/-- Its variables (`ModelVar`). -/',
    inductive('Var', ctors: [for (final v in ModelVar.values) v.name]),
    '',
    '/-- Its constants (`ModelConst`). -/',
    inductive('Const', ctors: [for (final c in ModelConst.values) c.tla]),
    '',
    '/-- Its invariants (`Inv`). -/',
    inductive('Inv', ctors: [for (final i in Inv.values) i.name]),
    '',
    '/-- The worlds the invariants are checked in, written and printed. -/',
    inductive('World', ctors: [for (final w in worlds) w.cfg]),
    '',
    '/-- What each action reads, as its declarations print it',
    '(`activation_footprints.tsv`). -/',
    'def declaredReads : Act → List Var',
    for (final (i, a) in actions.indexed)
      '  | .${names[i]} => ${vars(a.reads)}',
    '',
    '/-- What each action writes, as its declarations print it. -/',
    'def declaredWrites : Act → List Var',
    for (final (i, a) in actions.indexed)
      '  | .${names[i]} => ${vars(a.writes)}',
    '',
    '/-- What the footprint gate leaves out as the scheduler\'s and the',
    'checkers\', taken as read and written by every action. -/',
    'def scheduler : List Var := ${vars(_scheduler)}',
    '',
    '/-- What each way a flow reaches the action needs of the constants: set',
    '(`true`) or left (`false`). An action reached no way needs what no world',
    'gives. -/',
    'def ways : Act → List (List (Const × Bool))',
    for (final (i, a) in actions.indexed)
      '  | .${names[i]} => ${_list([for (final n in a.ways.values) _list(n.map(need))])}',
    '',
    '/-- The inputs `Allowed` gates (`Lands`). -/',
    'def inputs : List Act := ${_list([for (final n in names)
      if (inputs.contains(n)) '.$n'])}',
    '',
    '/-- The constants each world sets. -/',
    'def constants : World → List Const',
    for (final w in worlds)
      '  | .${w.cfg} => ${_list([for (final c in ModelConst.values)
        if (constantsOf(w.spec).contains(c)) '.${c.tla}'])}',
    '',
    '/-- The inputs each world allows, `none` for every one. -/',
    'def allowed : World → Option (List Act)',
    for (final w in worlds)
      '  | .${w.cfg} => ${switch (w.spec.allowed) {
        null => 'none',
        final s => 'some ${_list([for (final n in names)
          if (s.contains(n)) '.$n'])}',
      }}',
    '',
    '/-- The invariants each world checks. -/',
    'def checked : World → List Inv',
    for (final w in worlds)
      '  | .${w.cfg} => ${_list([for (final i in w.invariants) '.${i.name}'])}',
    '',
    'def gives (w : World) (n : List (Const × Bool)) : Bool :=',
    '  n.all fun (c, set) => (constants w).contains c == set',
    '',
    '/-- The world\'s constants give what some way to the action needs. -/',
    'def present (w : World) (a : Act) : Bool := (ways a).any (gives w)',
    '',
    '/-- Present, and an input only where the world allows it. -/',
    'def inWorld (w : World) (a : Act) : Bool :=',
    '  present w a && (!inputs.contains a || ((allowed w).map (·.contains a)).getD true)',
    '',
    '/-- Each invariant\'s reads as `Inv` declares them, which `footprint.py`',
    'holds to its text; one that holds at rest reads every row\'s place. -/',
    'def invReadsOf : Inv → List Var',
    for (final i in Inv.values)
      '  | .${i.name} => ${switch (i.reads) {
        null => 'Var.all',
        final reads => _list([
          for (final v in reads) '.${v.name}',
          if (i.atRest && !reads.contains(ModelVar.fl)) '.fl',
        ]),
      }}',
    '',
    'def footprints : Footprints Act Var Inv World where',
    '  acts := Act.all',
    '  vars := Var.all',
    '  reads a := declaredReads a ++ scheduler',
    '  writes a := declaredWrites a ++ scheduler',
    '  invs := Inv.all',
    '  invReads := invReadsOf',
    '  worlds := World.all',
    '  checks w i := (checked w).contains i',
    '  present := present',
    '  inWorld := inWorld',
    '',
    'theorem acts_complete : ∀ a, a ∈ footprints.acts := by',
    '  intro a; cases a <;> decide',
    '',
    'theorem vars_complete : ∀ v, v ∈ footprints.vars := by',
    '  intro v; cases v <;> decide',
    '',
    // Deciding it false, as formal/lean/check.sh's planted copy does,
    // recurses deeper than the default 512 once there are ~100 worlds.
    'set_option maxRecDepth 4096 in',
    'theorem every_invariant_licensed : footprints.everyInvariantLicensed = true := by',
    '  decide',
    '',
    '',
    '-- Per invariant: the worlds that check it, and those that take its cone.',
    '#eval Inv.all.map fun i =>',
    '  (i, (World.all.filter (footprints.checks · i)).length,',
    '    (World.all.filter fun w => footprints.checks w i && footprints.licensedB w i).length)',
    '',
    'end Activation',
    '',
  ].join('\n');
}
