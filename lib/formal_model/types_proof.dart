import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/step_print.dart';

/// The proof that every step keeps the flows' rows typed, as modules each
/// checked on its own: the lemmas it rests on, printed from the flow's
/// fields (a function of flow records updated in one field of one row, with
/// a value in that field's range, is still one, `Fl_<field>`; a field read
/// from one is in its range, `Rd_<field>`; `NoFlow` is a flow record, field
/// by field, since the provers do not take a record set of every field
/// whole); then each table's steps, one row of `fl` at a time; then every
/// step. SMT takes no string or record literal here, so what needs one is
/// Zenon's. A step opens the [definitions] its value reaches, through their
/// bodies, but no constant a world may set, which it takes by its range.
List<({String path, String text})> activationTypesProofs({
  required Map<String, List<FlStep>> tables,
  required Map<String, String> definitions,
}) {
  final opened = {
    for (final MapEntry(:key, :value) in definitions.entries)
      if (!_parameters.contains(key)) key: value,
  };
  final all = [for (final steps in tables.values) ...steps];
  final held = _heldOf(all, definitions: opened);
  final needs = {for (final h in held) h: _needs(h, steps: all)};
  final facts = _facts(definitions: definitions);
  return [
    _module('activation_types_proof', extending: 'activation, TLAPS', body: [
      '\\* Zenon for a moment, then SMT: an action whose rows each keep a fact',
      '\\* closes from their lemmas in a second by Zenon, where SMT can spend its',
      '\\* whole timeout on a long action before Zenon is tried.',
      'ZenonFirst == TRUE (*{ by (prover:"zenon"; timeout:1) by (prover:"smt3") }*)',
      '',
      '\\* What some steps need of their flow beyond TypeOK and Held at the place',
      '\\* they run from (_supports in lib/formal_model/types_proof.dart).',
      for (final MapEntry(key: place, value: fact) in _supports.entries)
        'Supported_$place(r) == $fact',
      'Supports == \\A g \\in Flows :',
      for (final place in _supports.keys)
        '    /\\ (fl[g].pc = "$place" => Supported_$place(fl[g]))',
      '',
      '\\* At most one flow of each of these kinds is in flight: an input that',
      '\\* starts one lands only once its gate did not hold (_alone).',
      'Alone == \\A g, h \\in Flows :',
      for (final k in _alone.keys)
        '    /\\ (fl[g].kind = "${k.name}" /\\ fl[h].kind = "${k.name}" => g = h)',
      '',
      for (final h in held) ...[
        '\\* Where a flow\'s ${h.field.name} is in ${h.set}: where a step needs it, and on',
        '\\* every way there that does not set it, for the kinds of flow that go',
        '\\* that way (_heldOf).',
        'Held_${h.field.name} == \\A g \\in Flows :',
        for (final (:places, :others) in _byOthers(needs[h]!))
          '    /\\ (fl[g].pc \\in ${_set(places)}${others.isEmpty ? '' : ' /\\ fl[g].kind \\notin ${_set(others)}'}'
              ' => fl[g].${h.field.name} \\in ${h.set})',
        '',
      ],
      'Held == ${[for (final h in held) 'Held_${h.field.name}'].join(' /\\ ')}',
      '',
      ..._proved(_pick),
      'LEMMA TypeFl ==',
      '    ASSUME TypeOK PROVE fl \\in [Flows -> FlowRecord]',
      '  BY Zenon DEF TypeOK',
      '',
      for (final (family: _, :lemmas, cites: _) in facts)
        for (final l in lemmas) ..._omitted(l),
      '\\* What a world may set each constant to; a proof opens no default a world',
      '\\* may replace.',
      'ASSUME ConstantsType ==',
      '    /\\ MaxInputs \\in Nat',
      for (final c in ModelConst.values)
        if (c.kind != ConstKind.fixed) '    /\\ ${c.tla} \\in ${c.range}',
      '',
      'LEMMA NoFlowType == NoFlow \\in FlowRecord',
      '  <1> USE DEF NoFlow',
      for (final (i, f) in FlowField.values.indexed) ...[
        '  <1>${i + 1}. NoFlow.${f.name} \\in ${f.range}',
        switch (_enumerated(f)) {
          // Zenon does no arithmetic.
          null when f.range.contains('..') => '    OBVIOUS',
          null => '    BY Zenon',
          final set => '    BY ${set}_${f.none.replaceAll('"', '')}',
        },
      ],
      '  <1> QED',
      '    BY ${[for (var i = 1; i <= FlowField.values.length; i++) '<1>$i'].join(', ')}',
      '       DEF FlowRecord',
      '',
      'LEMMA Fl_row ==',
      '    ASSUME NEW g \\in [Flows -> FlowRecord], NEW x \\in Flows,',
      '           NEW r \\in FlowRecord',
      '    PROVE  [g EXCEPT ![x] = r] \\in [Flows -> FlowRecord]',
      '  OBVIOUS',
    ]),
    for (final (:family, :lemmas, :cites) in facts)
      _module('activation_facts_${family}_proof',
          extending: 'activation_ops, TLAPS',
          body: [
            for (final l in cites) ..._omitted(l),
            for (final l in lemmas) ..._proved(l),
          ]),
    for (final (:name, :steps) in _parts(tables))
        _module(name,
            extending: 'activation_types_proof',
            body: [
              for (final s in steps) ...[
                for (final (k, row) in s.rows.indexed)
                  _rowTyped(
                    s.action,
                    at: k + 1,
                    row: _atPlace(row, of: s, held: held),
                    definitions: opened,
                  ),
                ..._statement(_keptTyped, s: s),
                '  BY ${[for (var k = 1; k <= s.rows.length; k++) 'FlRow_${s.action}_$k'].join(', ')}, ZenonFirst',
                '     DEF ${[s.action, if (s.input) 'Input', 'Starts', 'IndInv', ..._placeDefs(s, held: held)].join(', ')}',
                '',
              ],
            ]),
    // A module per held field: a cold module's memory grows with its rows
    // ([_rowsPerModule]), and each field proves every row again.
    for (final (:name, :steps) in _parts(tables))
      for (final h in held)
        _module(name.replaceFirst('activation_types_', 'activation_held_${h.field.name}_'),
            extending: 'activation_types_proof',
            body: [
              for (final s in steps) ...[
                for (final (k, row) in s.rows.indexed)
                  _rowHeld(
                    s,
                    at: k + 1,
                    row: _atPlace(row, of: s, held: held),
                    held: h,
                    need: needs[h]!,
                    definitions: opened,
                  ),
                ..._statement(_keptHeld(h.field), s: s),
                '  BY ${[for (var k = 1; k <= s.rows.length; k++) 'HdRow_${h.field.name}_${s.action}_$k'].join(', ')}, ZenonFirst',
                '     DEF ${[s.action, if (s.input) 'Input', 'Starts', 'IndInv', 'Held', ..._placeDefs(s, held: held)].join(', ')}',
                '',
              ],
            ]),
    for (final (:name, :steps) in _parts(tables))
      _module(name.replaceFirst('activation_types_', 'activation_supports_'),
          extending: 'activation_types_proof',
          body: [
            for (final s in steps) ...[
              for (final (k, row) in s.rows.indexed) _rowAlone(s, at: k + 1, row: row),
              ..._statement(_keptAlone, s: s),
              '  BY ${[for (var k = 1; k <= s.rows.length; k++) 'AlRow_${s.action}_$k'].join(', ')}, ZenonFirst',
              '     DEF ${[s.action, if (s.input) 'Input', 'Starts', 'IndInv'].join(', ')}',
              '',
              for (final (k, row) in s.rows.indexed)
                _rowSupported(
                  s,
                  at: k + 1,
                  row: _atPlace(row, of: s, held: held),
                  kinds: needs[held.firstWhere((h) => h.field == FlowField.kind)]!,
                  definitions: opened,
                ),
              ..._statement(_keptSupports, s: s),
              '  BY ${[for (var k = 1; k <= s.rows.length; k++) 'SpRow_${s.action}_$k'].join(', ')}, ZenonFirst',
              '     DEF ${[s.action, if (s.input) 'Input', 'Starts', 'IndInv', 'Held', ..._placeDefs(s, held: held)].join(', ')}',
              '',
            ],
          ]),
    for (final (:family, :kept) in _kept)
      _module('activation_${family}_steps_proof',
          extending: 'activation_types_proof',
          body: [
            for (final k in kept)
              for (final steps in tables.values)
                for (final s in steps) ...[..._statement(k, s: s), '  PROOF OMITTED', ''],
            for (final (over, input) in [('TableStep', false), ('InputTableStep', true)])
              for (final (:lemma, assume: _, :fact) in kept) ...[
                'LEMMA ${lemma}_$over ==',
                '    ASSUME TypeOK, IndInv, ConstantsType, Held, Supports, Alone, NEW f \\in Flows, $over(f)',
                '    PROVE  $fact',
                '  BY ${[for (final steps in tables.values) for (final s in steps) if (s.input == input) '${lemma}_${s.action}'].join(', ')}',
                '     DEF $over',
                '',
              ],
          ]),
  ];
}

/// A lemma as its statement and its proof, printed with the proof where it
/// is proved and omitted where it is restated.
typedef _Lemma = ({List<String> statement, String proof});

List<String> _proved(_Lemma l) => [...l.statement, l.proof, ''];

List<String> _omitted(_Lemma l) => [...l.statement, '  PROOF OMITTED', ''];

final _pick = (
  statement: [
    'LEMMA Pick ==',
    r'    ASSUME NEW g \in [Flows -> FlowRecord], NEW x \in Flows',
    '    PROVE  DOMAIN g[x] = {${[for (final f in FlowField.values) '"${f.name}"'].join(', ')}}',
  ],
  proof: '  BY DEF FlowRecord',
);

/// Each fact a row lemma reads of TypeOK or of a row's fields, proved once:
/// a case that unfolds TypeOK or states a row's whole domain takes tlapm
/// seconds to prepare for its backends, which then need none of it. A row
/// lemma cites them with Zenon: tlapm tries SMT first, and preparing its
/// input costs a second or more even where a cited fact is the step.
///
/// `activation_types_proof` states each family omitted, and a module of
/// the family's own proves it over `activation_ops`, which defines every
/// name the facts read, restating what it [cites]: tlapm holds every
/// obligation it proves afresh until the module ends, each with all its
/// module extends as its context, so the families proved over the whole
/// model took 8.7 GB cold and outgrew the runner with two more fields.
/// The members family alone took 4.4 GB over `activation`, 336 MB over
/// `activation_ops`.
List<({String family, List<_Lemma> lemmas, List<_Lemma> cites})> _facts({
  required Map<String, String> definitions,
}) => [
  (
    family: 'vars',
    cites: const [],
    lemmas: [
      for (final v in ModelVar.values)
        (
          statement: ['LEMMA Type_${v.name} ==', '    ASSUME TypeOK PROVE ${v.type}'],
          proof: '  BY Zenon DEF TypeOK',
        ),
    ],
  ),
  (
    family: 'domains',
    cites: [_pick],
    lemmas: [
      for (final f in FlowField.values)
        (
          statement: [
            'LEMMA Dom_${f.name} ==',
            r'    ASSUME NEW g \in [Flows -> FlowRecord], NEW x \in Flows',
            '    PROVE  "${f.name}" \\in DOMAIN g[x]',
          ],
          proof: '  BY Pick, Zenon',
        ),
    ],
  ),
  (
    family: 'members',
    cites: const [],
    lemmas: [
      for (final f in FlowField.values)
        if (_enumerated(f) case final set?)
          for (final m in _members(set, definitions: definitions))
            (statement: ['LEMMA ${set}_$m == "$m" \\in $set'], proof: '  BY Zenon DEF $set'),
    ],
  ),
  (
    family: 'fields',
    cites: const [],
    lemmas: [
      for (final f in FlowField.values) ...[
        (
          statement: [
            'LEMMA Fl_${f.name} ==',
            r'    ASSUME NEW g \in [Flows -> FlowRecord], NEW x \in Flows,',
            '           NEW val \\in ${f.range}',
            '    PROVE  [g EXCEPT ![x].${f.name} = val] \\in [Flows -> FlowRecord]',
          ],
          proof: '  BY DEF FlowRecord',
        ),
        (
          statement: [
            'LEMMA Rd_${f.name} ==',
            r'    ASSUME NEW g \in [Flows -> FlowRecord], NEW x \in Flows',
            '    PROVE  g[x].${f.name} \\in ${f.range}',
          ],
          proof: '  BY Zenon DEF FlowRecord',
        ),
      ],
    ],
  ),
];

/// A fact every step keeps: its lemmas' prefix, what they assume beside
/// the step, and the fact.
typedef _Kept = ({String lemma, String assume, String fact});

const _keptTyped = (
  lemma: 'Fl',
  assume: 'TypeOK, IndInv, Held, Supports',
  fact: r"fl' \in [Flows -> FlowRecord]",
);
_Kept _keptHeld(FlowField field) => (
  lemma: 'Hd_${field.name}',
  assume: 'TypeOK, IndInv, ConstantsType, Held, Supports',
  fact: "Held_${field.name}'",
);
const _keptAlone = (lemma: 'Al', assume: 'TypeOK, IndInv, ConstantsType, Alone', fact: "Alone'");
const _keptSupports = (
  lemma: 'Sp',
  assume: 'TypeOK, IndInv, ConstantsType, Held, Supports, Alone',
  fact: "Supports'",
);

/// [k]'s lemma for [s], as its table's module proves it and its family's
/// steps module restates it.
List<String> _statement(_Kept k, {required FlStep s}) => [
  'LEMMA ${k.lemma}_${s.action} ==',
  '    ASSUME ${k.assume}, NEW f \\in Flows, ${s.action}(f)',
  '    PROVE  ${k.fact}',
];

/// Each family of modules a fact is proved kept in, with its facts. A
/// family's steps module restates the steps' lemmas it cites, omitted,
/// over `activation_types_proof` alone: extending the tables' modules put
/// every row's lemma in each obligation's context, which cost tlapm 12 s an
/// obligation, the trivial ones too. `formal/proofs/omitted.py` holds each
/// restated lemma to the one its table's module proves.
final _kept = <({String family, List<_Kept> kept})>[
  (family: 'types', kept: [_keptTyped]),
  (family: 'held', kept: [for (final f in _heldFields) _keptHeld(f)]),
  (family: 'supports', kept: [_keptAlone, _keptSupports]),
];

/// The rows one module proves at most: tlapm holds every obligation it
/// proves afresh until the module ends, so a cold module's memory grows
/// with its rows. Twelve held rows took 6.4 GB on one thread (200 MB with
/// every obligation cached), and four modules prove side by side on a
/// 16 GB runner (`proofs/check_proofs.sh`).
const _rowsPerModule = 6;

/// [tables]' steps as the modules that prove them: a table's own, or its
/// numbered parts where it has more than [_rowsPerModule] rows, a step's
/// rows always in one.
List<({String name, List<FlStep> steps})> _parts(Map<String, List<FlStep>> tables) => [
  for (final MapEntry(key: table, value: steps) in tables.entries)
    if (steps.isNotEmpty) ...() {
      final parts = <List<FlStep>>[[]];
      var rows = 0;
      for (final s in steps) {
        if (rows > 0 && rows + s.rows.length > _rowsPerModule) {
          parts.add([]);
          rows = 0;
        }
        parts.last.add(s);
        rows += s.rows.length;
      }
      return [
        for (final (k, part) in parts.indexed)
          (
            name: parts.length == 1
                ? 'activation_types_${table}_proof'
                : 'activation_types_$table${k + 1}_proof',
            steps: part,
          ),
      ];
    }(),
];

/// The definitions a step's lemma opens to give its rows the facts of its
/// place ([_placeFacts]).
List<String> _placeDefs(FlStep s, {required List<_Held> held}) => <String>{
  if (!s.input) ...[
    for (final h in held)
      if (h.at.contains(s.place)) ...['Held', 'Held_${h.field.name}'],
    if (_supports.containsKey(s.place)) ...['Supports', 'Supported_${s.place}'],
  ],
}.toList();

/// [row] with what its step may take of the place it runs from
/// ([_placeFacts]).
FlRow _atPlace(FlRow row, {required FlStep of, required List<_Held> held}) => (
  picks: row.picks,
  lets: row.lets,
  given: [if (!of.input) ..._placeFacts(of.place, held: held), ...row.given],
  clauses: row.clauses,
  tested: row.tested,
  passed: row.passed,
  writes: row.writes,
);

/// The lemma that [row] of [s] keeps `Held_<field>` of [held]: the field
/// of each row it writes is in the set wherever that row goes to a place
/// and a kind in [need], by its value where the row sets it and by the
/// place and kind it came from where it keeps it; every other row is as
/// it was.
String _rowHeld(
  FlStep s, {
  required int at,
  required FlRow row,
  required _Held held,
  required Map<String, Set<String>> need,
  required Map<String, String> definitions,
}) {
  final field = held.field.name;
  final spawns = row.clauses.any((c) => c.startsWith('![inputs + 1]'));
  assert(!spawns || !s.input, '${s.action} starts a flow beside its input');
  final entries = _entries(row);
  // A row that keeps the field needs only where it came from and the tests
  // of its kind: what its picks range over can only bury those.
  final sets = entries.any((e) => e.values.containsKey(field));
  final assume = [
    'TypeOK',
    'ConstantsType',
    'Held_$field',
    r'NEW f \in Flows',
    for (final p in row.picks) sets ? 'NEW ${p.name} \\in ${p.from}' : 'NEW ${p.name}',
    for (final l in row.lets) ...['NEW ${l.name}', if (sets) '${l.name} = ${l.to}'],
    if (sets || row.tested != null) ...row.given,
    if (!s.input) ...[
      'fl[f].pc = "${s.place}"',
      for (final p in row.passed)
        if (p.kinds.isNotEmpty) p.tla,
    ],
    if (spawns) ...[r'inputs \in Nat', 'inputs < MaxInputs', 'Fresh'],
    "fl' = [fl EXCEPT ${row.clauses.join(', ')}]",
  ];
  final bound = {
    for (final p in row.picks) p.name: p.from,
    for (final l in row.lets) l.name: l.to,
  };
  final read = <ModelVar>{};
  final proved = [
    for (final (i, (index: _, :places, ends: _, :values)) in entries.indexed)
      if (values[field] case final value? when places.any(need.containsKey))
        (
          label: '<1>v$i',
          lines: [
            '  <1>v$i. ($value) \\in ${held.set}',
            '    ${_typed(value, field: held.field, range: held.set, bound: bound, given: row.given, definitions: definitions, read: read)}',
          ],
        ),
  ];
  final (:steps, :facts) = _readBack(
    entries,
    fields: [if (held.field != FlowField.kind) 'kind', field],
    of: s,
  );
  return [
    'LEMMA HdRow_${field}_${s.action}_$at ==',
    '    ASSUME ${assume.join(',\n           ')}',
    "    PROVE  Held_$field'",
    '  <1>0. fl \\in [Flows -> FlowRecord]',
    '    BY TypeFl, Zenon',
    if (spawns) ..._started,
    for (final v in ModelVar.values)
      if (read.contains(v)) ...['  <1>${_typeStep(v)}. ${v.type}', '    BY Type_${v.name}, Zenon'],
    for (final p in proved) ...p.lines,
    ...steps,
    ..._others(spawns: spawns),
    '  <1> QED',
    '    BY ${[for (final p in proved) p.label, ...facts, '<1>o', if (spawns) '<1>s'].join(', ')}, Zenon DEF Held_$field',
    '',
  ].join('\n');
}

/// The lemma that [row] of [s] keeps `Alone`: a row it starts as a kind of
/// [_alone] lands only once that kind's gate did not hold, so no other
/// flow is of it; every other row keeps its kind, ends, or starts as
/// another.
String _rowAlone(FlStep s, {required int at, required FlRow row}) {
  final spawns = row.clauses.any((c) => c.startsWith('![inputs + 1]'));
  final entries = _entries(row);
  final gates = <ModelDef>{
    for (final (:index, places: _, ends: _, :values) in entries)
      for (final MapEntry(key: kind, value: gate) in _alone.entries)
        if (values['kind'] == '"${kind.name}"') () {
          assert(s.input && index == 'f', '${s.action} gives a flow the kind ${kind.name} on its way');
          assert(_keepsOut(row, gate: gate),
              '${s.action} starts a ${kind.name} flow whatever ${gate.tla} says');
          return gate;
        }(),
  };
  final (:steps, :facts) = _readBack(entries, fields: ['kind'], of: s);
  return [
    'LEMMA AlRow_${s.action}_$at ==',
    '    ASSUME ${[
      'TypeOK',
      'ConstantsType',
      'Alone',
      r'NEW f \in Flows',
      for (final p in row.picks) 'NEW ${p.name}',
      for (final l in row.lets) 'NEW ${l.name}',
      if (!s.input) 'fl[f].pc = "${s.place}"',
      for (final g in gates) '~(${g.tla})',
      if (spawns) ...[r'inputs \in Nat', 'inputs < MaxInputs', 'Fresh'],
      "fl' = [fl EXCEPT ${row.clauses.join(', ')}]",
    ].join(',\n           ')}',
    "    PROVE  Alone'",
    '  <1>0. fl \\in [Flows -> FlowRecord]',
    '    BY TypeFl, Zenon',
    if (spawns) ..._started,
    ...steps,
    ..._others(spawns: spawns),
    '  <1> QED',
    // Zenon loses its way beside a row whose next place is a long choice;
    // the default provers do not.
    '    BY ${[...facts, '<1>o', if (spawns) '<1>s'].join(', ')} DEF ${['Alone', if (gates.isNotEmpty) ...[for (final g in gates) g.tla, 'Kinds']].join(', ')}',
    '',
  ].join('\n');
}

/// Whether [row] lands only where [gate] does not hold: a branch before it
/// held where the gate does, or its input is enabled only without it.
bool _keepsOut(FlRow row, {required ModelDef gate}) =>
    row.passed.any((p) => p.tla == '~(${gate.tla})') ||
    row.given.contains('~(${gate.tla})');

/// What [row]'s arm leaves of [vars], for a lemma over the row that reads
/// them primed: each write of one, then that the arm keeps each other.
List<String> _leaves(FlRow row, {required List<ModelVar> vars}) => [
  for (final w in row.writes)
    if (w.vars.any(vars.contains)) w.tla,
  for (final v in vars)
    if (!row.writes.any((w) => w.vars.contains(v))) "${v.name}' = ${v.name}",
];

/// The lemma that [row] of [s] keeps `Supports`: a row it sends to a
/// supported place has its fact there, by its values or as it had it at
/// that place; where the row writes a variable a fact reads, no other flow
/// is at a supported place, since only a kind of [_alone] is ([_heldOf]) and
/// the row passed that kind's gate or runs as it; every other row is as it
/// was. [kinds] is where `Held_kind` holds its kind, by kinds of flow.
String _rowSupported(
  FlStep s, {
  required int at,
  required FlRow row,
  required Map<String, Set<String>> kinds,
  required Map<String, String> definitions,
}) {
  final spawns = row.clauses.any((c) => c.startsWith('![inputs + 1]'));
  final entries = _entries(row);
  final facts = _supports.values.join(' ');
  final fields = {for (final m in RegExp(r'\br\.(\w+)').allMatches(facts)) m[1]!}.toList()..sort();
  final opens = _reached(facts, definitions: definitions);
  final shared = _supportedReads(definitions);
  final moves = _moves(row, shared: shared);
  final gates = [
    for (final g in _alone.values)
      if (_keepsOut(row, gate: g)) g,
  ];
  assert(
    !moves || gates.isNotEmpty || (kinds[s.place]?.containsAll(_kinds) ?? false),
    '${s.action} writes what a supported fact reads beside a flow it does not keep out',
  );
  // The rows that arrive at a supported place other than as they were there.
  final arrives = [
    for (final (i, e) in entries.indexed)
      if (!e.ends && e.places.any(_supports.containsKey))
        if (s.input || moves || !e.places.contains(s.place) || fields.any(e.values.containsKey)) (i, e),
  ];
  assert(arrives.every((a) => a.$2.index == 'f'), '${s.action} starts a flow at a supported place');
  final (:steps, facts: read) = _readBack(entries, fields: fields, of: s);
  final reached = [
    for (final (i, e) in arrives)
      for (final p in e.places.where(_supports.containsKey))
        (
          label: '<1>v$i$p',
          lines: [
            "  <1>v$i$p. fl'[f].pc = \"$p\" => (Supported_$p(fl[f]))'",
            '    BY <1>w$i, Zenon DEF ${['Supported_$p', ...opens].join(', ')}',
          ],
        ),
  ];
  return [
    'LEMMA SpRow_${s.action}_$at ==',
    '    ASSUME ${[
      'TypeOK',
      'ConstantsType',
      'Supports',
      if (moves) ...['Held_kind', 'Alone'],
      r'NEW f \in Flows',
      for (final p in row.picks) arrives.isEmpty ? 'NEW ${p.name}' : 'NEW ${p.name} \\in ${p.from}',
      for (final l in row.lets) ...['NEW ${l.name}', if (arrives.isNotEmpty) '${l.name} = ${l.to}'],
      if (arrives.isNotEmpty) ...row.given,
      if (!s.input) 'fl[f].pc = "${s.place}"',
      if (moves) for (final g in gates) '~(${g.tla})',
      if (spawns) ...[r'inputs \in Nat', 'inputs < MaxInputs', 'Fresh'],
      "fl' = [fl EXCEPT ${row.clauses.join(', ')}]",
      ..._leaves(row, vars: shared),
    ].join(',\n           ')}',
    "    PROVE  Supports'",
    '  <1>0. fl \\in [Flows -> FlowRecord]',
    '    BY TypeFl, Zenon',
    if (spawns) ..._started,
    ...steps,
    for (final r in reached) ...r.lines,
    if (moves) ...[
      '  <1>a. \\A g \\in Flows : g # f => fl[g].pc \\notin ${_set(_supports.keys.toList())}',
      '    BY Zenon DEF ${['Held_kind', 'Alone', if (gates.isNotEmpty) ...[for (final g in gates) g.tla, 'Kinds']].join(', ')}',
    ],
    ..._others(spawns: spawns),
    '  <1> QED',
    '    BY ${[
      ...read,
      for (final r in reached) r.label,
      if (moves) '<1>a',
      '<1>o',
      if (spawns) '<1>s',
    ].join(', ')}, Zenon DEF ${['Supports', for (final p in _supports.keys) 'Supported_$p', ...opens].join(', ')}',
    '',
  ].join('\n');
}

/// The steps that read back each row [entries] writes: its domain, then
/// the place it goes to and each of [fields], by the value the row gives
/// it or as it was; a row it ends, by its place (and kind, among [fields])
/// as NoFlow's. The domain is stated first: Zenon does not find it through
/// `Pick` beside a value it cannot see past.
({List<String> steps, List<String> facts}) _readBack(
  List<_Entry> entries, {
  required List<String> fields,
  required FlStep of,
}) {
  final steps = <String>[];
  final facts = <String>[];
  // Beside a flow it starts, each row reads back only as the other's
  // number differs.
  final started = entries.length > 1 ? '<1>s, ' : '';
  for (final (i, (:index, :places, :ends, :values)) in entries.indexed) {
    assert(ends || places.isNotEmpty, '${of.action} writes a row it sends to no place');
    final at = index == 'f' ? 'f' : 'inputs + 1';
    if (ends) {
      steps.addAll([
        "  <1>w$i. fl'[$at].pc = ${FlowField.pc.none}"
            "${fields.contains('kind') ? " /\\ fl'[$at].kind = ${FlowField.kind.none}" : ''}",
        '    BY <1>0, ${started}Zenon DEF NoFlow',
      ]);
    } else {
      steps.addAll([
        '  <1>d$i. ${[for (final f in {'pc', ...fields}) '"$f" \\in DOMAIN fl[$at]'].join(' /\\ ')}',
        '    BY <1>0, $started${[for (final f in {'pc', ...fields}) 'Dom_$f'].join(', ')}, Zenon',
        "  <1>w$i. /\\ fl'[$at].pc \\in ${_set(places.toList()..sort())}",
        for (final f in fields) "        /\\ fl'[$at].$f = (${values[f] ?? 'fl[$at].$f'})",
        '    BY <1>0, <1>d$i, ${started}Zenon',
      ]);
    }
    facts.add('<1>w$i');
  }
  return (steps: steps, facts: facts);
}

/// The steps that give a row lemma the flow its row starts: numbered next,
/// a flow, and not the one that starts it, which has started already.
const _started = [
  '  <1>n. ~(f > inputs)',
  '    BY Zenon DEF Fresh',
  r'  <1>s. inputs + 1 \in Flows /\ f # inputs + 1',
  '    BY <1>n, ConstantsType DEF Flows',
];

/// The step of a row lemma that every row but the ones it writes is as it
/// was.
List<String> _others({required bool spawns}) => [
  "  <1>o. \\A g \\in Flows : g # f${spawns ? r' /\ g # inputs + 1' : ''} => fl'[g] = fl[g]",
  '    BY <1>0, Zenon',
];

({String path, String text}) _module(
  String name, {
  required String extending,
  required List<String> body,
}) => (
  path: '$name.tla',
  text: [
    '${'-' * 16} MODULE $name ${'-' * 16}',
    '(* Printed from FlowField and the step tables by lib/formal_model/main.dart. *)',
    '(* Not committed; edit the declarations instead.                          *)',
    'EXTENDS $extending',
    '',
    ...body,
    '',
    '=' * 77,
    '',
  ].join('\n'),
);

/// The lemma that [row] of [action] keeps `fl` a function of flow records:
/// its clauses applied one at a time, each a step that its value is in its
/// field's range, over only what the value reads, and a step by the lemma
/// for the field it sets. Each partial row is named, so a step's obligation
/// holds one clause over the name before it, not every clause before it.
String _rowTyped(
  String action, {
  required int at,
  required FlRow row,
  required Map<String, String> definitions,
}) {
  final spawns = row.clauses.any((c) => c.startsWith('![inputs + 1]'));
  // A field of the flow a row starts may read the state the arm leaves; a
  // value in a set of strings needs only its literals.
  final primed = [
    for (final v in ModelVar.values)
      if (v != ModelVar.fl &&
          row.clauses.any((c) {
            final name = RegExp(r'^!\[.+?\]\.(\w+) = ').firstMatch(c)?[1];
            return name != null &&
                _enumerated(FlowField.values.byName(name)) == null &&
                RegExp("\\b${v.name}'").hasMatch(c);
          }))
        v,
  ];
  final given = [...row.given, ..._leaves(row, vars: primed)];
  final context = [
    'TypeOK',
    r'NEW f \in Flows',
    for (final p in row.picks) 'NEW ${p.name} \\in ${p.from}',
    for (final l in row.lets) ...['NEW ${l.name}', '${l.name} = ${l.to}'],
    ...given,
  ];
  final assume = [
    ...context,
    if (spawns) ...[r'inputs \in Nat', 'inputs < MaxInputs'],
    "fl' = [fl EXCEPT ${row.clauses.join(', ')}]",
  ];
  final bound = {
    for (final p in row.picks) p.name: p.from,
    for (final l in row.lets) l.name: l.to,
  };
  final steps = [
    if (spawns) ...[
      '  <1>s. inputs + 1 \\in Flows',
      '    BY ConstantsType DEF Flows',
    ],
  ];
  final read = <ModelVar>{};
  final clauses = <String>[];
  // A value over the state the arm leaves is typed in a lemma of its own,
  // whose context holds the arm's writes and not the row's partial
  // functions, which bury it.
  final own = <String>[];
  for (final (i, c) in row.clauses.indexed) {
    final m = RegExp(r'^!\[(.+?)\](?:\.(\w+))? = (.*)$').firstMatch(c)!;
    final (index, name, value) = (m[1]!, m[2], m[3]!);
    final field = name == null ? null : FlowField.values.byName(name);
    assert(field != null || value == 'NoFlow', '$action sets a row to $value');
    final before = i == 0 ? 'fl' : 'fl$i';
    final leaves = field != null &&
        _enumerated(field) == null &&
        primed.any((v) => RegExp("\\b${v.name}'").hasMatch(value));
    if (leaves) {
      final reads = <ModelVar>{};
      final proof = _typed(value, field: field, range: field.range, bound: bound, given: given, definitions: definitions, read: reads);
      own.addAll([
        'LEMMA FlRow_${action}_${at}_${field.name} ==',
        '    ASSUME ${context.join(',\n           ')}',
        '    PROVE  ($value) \\in ${field.range}',
        '  <1>0. fl \\in [Flows -> FlowRecord]',
        '    BY TypeFl, Zenon',
        for (final v in ModelVar.values)
          if (reads.contains(v)) ...['  <1>${_typeStep(v)}. ${v.type}', '    BY Type_${v.name}, Zenon'],
        '  <1> QED',
        '    $proof',
        '',
      ]);
    }
    clauses.addAll([
      '  <1> DEFINE fl${i + 1} == [$before EXCEPT $c]',
      '  <1>${2 * i + 1}. ($value) \\in ${field?.range ?? 'FlowRecord'}',
      switch (field) {
        null => '    BY NoFlowType',
        final field when leaves => '    BY FlRow_${action}_${at}_${field.name}, Zenon',
        final field => '    ${_typed(value, field: field, range: field.range, bound: bound, given: given, definitions: definitions, read: read)}',
      },
      '  <1>${2 * i + 2}. fl${i + 1} \\in [Flows -> FlowRecord]',
      '    BY ${i == 0 ? '<1>0' : '<1>${2 * i}'}, <1>${2 * i + 1}, '
          '${field == null ? 'Fl_row' : 'Fl_${field.name}'}'
          '${index == 'f' ? '' : ', <1>s'}, Zenon DEF fl${i + 1}',
    ]);
  }
  steps.addAll([
    for (final v in ModelVar.values)
      if (read.contains(v)) ...['  <1>${_typeStep(v)}. ${v.type}', '    BY Type_${v.name}, Zenon'],
    ...clauses,
  ]);
  final n = row.clauses.length;
  return [
    ...own,
    'LEMMA FlRow_${action}_$at ==',
    '    ASSUME ${assume.join(',\n           ')}',
    "    PROVE  fl' \\in [Flows -> FlowRecord]",
    '  <1>0. fl \\in [Flows -> FlowRecord]',
    '    BY TypeFl, Zenon',
    ...steps,
    "  <1>e. fl' = fl$n",
    '    BY Zenon DEF ${[for (var i = 1; i <= n; i++) 'fl$i'].join(', ')}',
    '  <1> QED',
    '    BY <1>${2 * n}, <1>e, Zenon',
    '',
  ].join('\n');
}

/// The proof that [value] is in [field]'s range: for a set of strings, the
/// set by Zenon, since its literals alone are members; for another range,
/// what it and its range read: the guards in [given] it shares a variable
/// or definition with, the [definitions] it, they and the picks it names
/// reach, the types of the variables any of that reads (added to [read],
/// for the lemma to state), the constants' ranges, and the rows of `fl` it
/// reads by their field's lemma.
String _typed(
  String value, {
  required FlowField field,
  required String range,
  required Map<String, String> bound,
  required List<String> given,
  required Map<String, String> definitions,
  required Set<ModelVar> read,
}) {
  if (_enumerated(field) case final set?) {
    final facts = [
      for (final m in RegExp(r'"(\w+)"').allMatches(value)) '${set}_${m[1]}',
      if (_rows(value) case final rows when rows.isNotEmpty) ...['<1>0', ...rows],
    ];
    return 'BY Zenon, ${{...facts}.join(', ')}';
  }
  final own = [
    value,
    range,
    for (final MapEntry(key: name, value: from) in bound.entries)
      if (RegExp('\\b$name\\b').hasMatch(value)) from,
  ].join(' ');
  final reads = _names(_closure(own, definitions: definitions), definitions: definitions);
  final named = [
    own,
    for (final g in given)
      if (_names(_closure(g, definitions: definitions), definitions: definitions)
          .intersection(reads)
          .isNotEmpty)
        g,
  ].join(' ');
  final opened = _reached(named, definitions: definitions);
  final text = _closure(named, definitions: definitions);
  final rows = _rows(text);
  final vars = [
    for (final v in ModelVar.values)
      if (v != ModelVar.fl && RegExp('\\b${v.name}\\b').hasMatch(text)) v,
  ];
  read.addAll(vars);
  final constants =
      opened.isNotEmpty || _parameters.any((c) => RegExp('\\b$c\\b').hasMatch(text));
  final facts = [
    if (constants || vars.isNotEmpty) 'ConstantsType',
    for (final v in vars) '<1>${_typeStep(v)}',
    if (rows.isNotEmpty) ...['<1>0', ...rows],
  ];
  // A value read off a function's function is typed by its variable's
  // type, stated over `Sites`, which opened into `1..N` the provers no
  // longer match.
  final folded = RegExp(r'\]\[').hasMatch(value)
      ? {'Sites', ..._reached('Sites', definitions: definitions)}
      : const <String>{};
  final defs = opened.where((d) => !folded.contains(d)).toList();
  if (facts.isEmpty && defs.isEmpty) return 'OBVIOUS';
  return [
    'BY',
    if (facts.isNotEmpty) facts.join(', '),
    if (defs.isNotEmpty) 'DEF ${defs.join(', ')}',
  ].join(' ');
}

/// The step of a row lemma that states [v]'s conjunct of `TypeOK`, which a
/// value that reads [v] cites: opening `TypeOK` whole beside a value's own
/// definitions (the sets it ranges over among them) leaves the provers a
/// conjunction too wide to close.
String _typeStep(ModelVar v) => 't${v.name}';

/// What a step needs of its flow beyond `TypeOK` and [_heldOf], by the place
/// it runs from, over the flow `g`, each a definition over the row
/// (`Supported_<place>`): proved kept by every step (`Supports`), by the
/// ways into the place and, where a step writes a variable it reads, by no
/// other flow being there ([_alone]).
const _supports = <String, String>{
  'tRemove': r'r.rest = {} => HasFresh(r.site)',
};

/// The kinds of flow of which at most one is in flight, each with the
/// definition every input that starts one is taken only once it did not
/// hold: the tab gate (`TabTable.tabBusy`).
final _alone = {FlowKind.tab: ModelDef.tabBusy};

/// A field a flow holds in a set narrower than its range wherever a step
/// needs it: the places [at], and each place an arm leaves from that
/// enters one of them without setting the field ([_needs]). Proved kept by
/// every step (`Held_<field>`).
typedef _Held = ({FlowField field, String set, Set<String> at});

/// The fields [_heldOf] holds, in the order `Held` conjoins them.
const _heldFields = [FlowField.site, FlowField.tab, FlowField.kind];

/// Where each of [_heldFields] is held over [steps]. The site's and the
/// tab's places are where a value a step writes needs the field in its set
/// beyond what `IndInv` gives, which the tables do not say, so they are
/// named. The kind's follow from [_supports]: what a supported fact reads
/// of the shared state only a flow of a kind in [_alone] writes, so its
/// places hold only those, and so does every place whose step writes it
/// beside them ([_unguarded]).
List<_Held> _heldOf(Iterable<FlStep> steps, {required Map<String, String> definitions}) => [
  for (final field in _heldFields)
    switch (field) {
      FlowField.site => (field: field, set: 'Sites', at: {'rLoad', 'tNav', 'tRebind', 'tDupRead', 'tRemove', 'rFlip', 'hLand', 'oLand'}),
      FlowField.tab => (field: field, set: 'TabIds', at: {'tNav', 'tRebind', 'tDupRead'}),
      FlowField.kind => (
        field: field,
        set: _set([for (final k in _alone.keys) k.name]),
        at: {..._supports.keys, ..._unguarded(steps, definitions: definitions)},
      ),
      final other => throw ArgumentError.value(other, 'field', 'not held'),
    },
];

/// The places whose step writes what a supported fact reads in a row no
/// gate of [_alone] keeps out, so a flow of that kind may be beside it.
Set<String> _unguarded(Iterable<FlStep> steps, {required Map<String, String> definitions}) {
  final shared = _supportedReads(definitions);
  return {
    for (final s in steps)
      if (!s.input)
        for (final row in s.rows)
          if (_moves(row, shared: shared) && !_alone.values.any((g) => _keepsOut(row, gate: g))) s.place,
  };
}

/// The shared variables a fact of [_supports] reads, through the
/// [definitions] it reaches.
List<ModelVar> _supportedReads(Map<String, String> definitions) {
  final reads = _closure(_supports.values.join(' '), definitions: definitions);
  return [
    for (final v in ModelVar.values)
      if (v != ModelVar.fl && RegExp('\\b${v.name}\\b').hasMatch(reads)) v,
  ];
}

/// Whether [row] writes one of [shared].
bool _moves(FlRow row, {required List<ModelVar> shared}) =>
    row.writes.any((w) => w.vars.any(shared.contains));

/// The kinds of flow a row can hold, as the model names them: a row no
/// input has started holds none.
final _kinds = {FlowField.kind.none.replaceAll('"', ''), for (final k in FlowKind.values) k.name};

/// The kinds of flow [held]'s field must be in its set for at each place:
/// every kind at the places it names, and back from each, at the place of
/// every arm that enters one without setting the field, the kinds the arm
/// is taken for that arrive as a kind needed there. An input or a started
/// flow that arrives as one must set it.
Map<String, Set<String>> _needs(_Held held, {required Iterable<FlStep> steps}) {
  final need = {for (final p in held.at) p: {..._kinds}};
  bool needed(Set<String> places, {required String kind}) =>
      places.any((p) => need[p]?.contains(kind) ?? false);
  var moved = true;
  while (moved) {
    moved = false;
    for (final s in steps) {
      for (final row in s.rows) {
        for (final (:index, :places, :values, ends: _) in _entries(row)) {
          final kind = values['kind']?.replaceAll('"', '');
          final value = values[held.field.name];
          if (value != null) continue;
          if (index != 'f' || s.input) {
            assert(!(switch (kind) { null => _kinds, final k => {k} }).any((k) => needed(places, kind: k)),
                '${s.action} enters ${places.where(need.containsKey)} without its ${held.field.name}');
            continue;
          }
          for (final k in _taken(row)) {
            if (needed(places, kind: kind ?? k)) moved |= need.putIfAbsent(s.place, () => {}).add(k);
          }
        }
      }
    }
  }
  return need;
}

/// A row of `fl` a row writes: its index (`f`, or `inputs + 1` for the
/// flow it starts), the places it goes to, whether it ends the flow, and
/// the value of each other field it sets, as printed.
typedef _Entry = ({String index, Set<String> places, bool ends, Map<String, String> values});

/// The rows [row] writes.
List<_Entry> _entries(FlRow row) {
  final out = <String, _Entry>{};
  for (final c in row.clauses) {
    final m = RegExp(r'^!\[(.+?)\](?:\.(\w+))? = (.*)$').firstMatch(c)!;
    final (index, name, value) = (m[1]!, m[2], m[3]!);
    final was = out[index] ?? (index: index, places: <String>{}, ends: false, values: <String, String>{});
    out[index] = switch (name) {
      null => (index: index, places: {FlowField.pc.none.replaceAll('"', '')}, ends: true, values: was.values),
      'pc' => (
        index: index,
        places: {...was.places, for (final p in RegExp(r'"(\w+)"').allMatches(value)) p[1]!},
        ends: was.ends,
        values: was.values,
      ),
      final n => (index: index, places: was.places, ends: was.ends, values: {...was.values, n: value}),
    };
  }
  return [...out.values];
}

/// The kinds of flow [row] is taken for: those its branch holds for, or
/// any, less those the branches before it held for.
Set<String> _taken(FlRow row) => {
  ...switch (row.tested) {
    null => _kinds,
    final kinds => {for (final k in kinds) k.name},
  },
}.difference({
  for (final p in row.passed)
    for (final k in p.kinds) k.name,
});

/// The places of [need] grouped by the kinds of flow not needed there.
List<({List<String> places, List<String> others})> _byOthers(Map<String, Set<String>> need) {
  final groups = <String, ({List<String> places, List<String> others})>{};
  for (final p in need.keys.toList()..sort()) {
    final others = [for (final k in _kinds) if (!need[p]!.contains(k)) k]..sort();
    groups.putIfAbsent(others.join(' '), () => (places: [], others: others)).places.add(p);
  }
  return [for (final k in groups.keys.toList()..sort()) groups[k]!];
}

/// [names] as a set of the model's strings.
String _set(List<String> names) => '{${[for (final n in names) '"$n"'].join(', ')}}';

/// What a step at [place] may take of its flow beyond `TypeOK`: each field
/// [held] names there, and what [_supports] holds there.
List<String> _placeFacts(String place, {required List<_Held> held}) => [
  for (final h in held)
    if (h.at.contains(place)) 'fl[f].${h.field.name} \\in ${h.set}',
  if (_supports[place] case final fact?) fact.replaceAll(RegExp(r'\br\.'), 'fl[f].'),
];

/// The constants a world may set, which a proof takes by their range alone.
final _parameters = {
  for (final c in ModelConst.values)
    if (c.kind != ConstKind.fixed) c.tla,
};

/// The variables, constants and [definitions] [tla] names, the shared state
/// a guard and a value may have in common.
Set<String> _names(String tla, {required Map<String, String> definitions}) => {
  for (final m in RegExp(r'\b([A-Za-z]\w*)\b').allMatches(tla))
    if (definitions.containsKey(m[1]) ||
        _parameters.contains(m[1]) ||
        ModelVar.values.any((v) => v.name == m[1] && v != ModelVar.fl))
      m[1]!,
  ..._rows(tla),
};

/// [tla] with the bodies of the [definitions] it reaches.
String _closure(String tla, {required Map<String, String> definitions}) => [
  tla,
  for (final d in _reached(tla, definitions: definitions)) definitions[d]!,
].join(' ');

/// The lemmas for the fields of `fl`'s rows [tla] reads.
Set<String> _rows(String tla) => {
  for (final m in RegExp(r'\bfl\[[^\]]+\]\.(\w+)').allMatches(tla)) 'Rd_${m[1]}',
};

/// The [definitions] [tla] calls, and those their bodies call, by name.
Set<String> _reached(String tla, {required Map<String, String> definitions}) {
  final reached = <String>{};
  var frontier = [tla];
  while (frontier.isNotEmpty) {
    frontier = [
      for (final text in frontier)
        for (final m in RegExp(r'\b([A-Z]\w*)\b').allMatches(text))
          if (definitions[m[1]] case final body? when reached.add(m[1]!)) body,
    ];
  }
  return reached;
}

/// Each definition in [modules] by name, its body as written: a line that
/// starts `Name ==` or `Name(...) ==` opens one, which runs to the next line
/// that starts at the margin.
Map<String, String> tlaDefinitions(List<String> modules) {
  final defs = <String, String>{};
  for (final module in modules) {
    String? name;
    final body = StringBuffer();
    void close() {
      if (name case final n?) defs[n] = body.toString();
      name = null;
      body.clear();
    }

    for (final line in module.split('\n')) {
      final opens = RegExp(r'^([A-Z]\w*)(?:\(.*?\))?\s*==(.*)$').firstMatch(line);
      if (opens != null) {
        close();
        name = opens[1];
        body.writeln(opens[2]);
      } else if (line.isEmpty || line.startsWith(' ')) {
        if (name != null) body.writeln(line);
      } else {
        close();
      }
    }
    close();
  }
  return defs;
}

/// The strings [set] holds, as its printed definition lists them.
List<String> _members(String set, {required Map<String, String> definitions}) => [
  for (final m in RegExp(r'"(\w+)"').allMatches(definitions[set]!)) m[1]!,
];

/// The set [field]'s range names where its values are strings, which Zenon
/// proves members of and SMT does not; a field whose values are strings
/// starts as one.
String? _enumerated(FlowField field) => field.none.startsWith('"') ? field.range : null;
