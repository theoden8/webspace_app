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
  return [
    _module('activation_types_proof', extending: 'activation, TLAPS', body: [
      '\\* What some steps need of their flow beyond TypeOK at the place they run',
      '\\* from (_supports in lib/formal_model/types_proof.dart); a proof that',
      '\\* every step keeps it is owed.',
      'Supports == \\A g \\in Flows :',
      for (final MapEntry(key: place, value: fact) in _supports.entries)
        '    /\\ (fl[g].pc = "$place" => ($fact))',
      '',
      '\\* What a world may set each constant to; a proof opens no default a world',
      '\\* may replace.',
      'ASSUME ConstantsType ==',
      '    /\\ MaxInputs \\in Nat',
      for (final c in ModelConst.values)
        if (c.kind != ConstKind.fixed) '    /\\ ${c.tla} \\in ${c.range}',
      '',
      for (final f in FlowField.values)
        if (_enumerated(f) case final set?)
          for (final m in _members(set, definitions: definitions)) ...[
            'LEMMA ${set}_$m == "$m" \\in $set',
            '  BY Zenon DEF $set',
            '',
          ],
      for (final f in FlowField.values) ...[
        'LEMMA Fl_${f.name} ==',
        '    ASSUME NEW g \\in [Flows -> FlowRecord], NEW x \\in Flows,',
        '           NEW val \\in ${f.range}',
        '    PROVE  [g EXCEPT ![x].${f.name} = val] \\in [Flows -> FlowRecord]',
        '  BY DEF FlowRecord',
        '',
        'LEMMA Rd_${f.name} ==',
        '    ASSUME NEW g \\in [Flows -> FlowRecord], NEW x \\in Flows',
        '    PROVE  g[x].${f.name} \\in ${f.range}',
        '  BY DEF FlowRecord',
        '',
      ],
      'LEMMA NoFlowType == NoFlow \\in FlowRecord',
      '  <1> USE DEF NoFlow',
      for (final (i, f) in FlowField.values.indexed) ...[
        '  <1>${i + 1}. NoFlow.${f.name} \\in ${f.range}',
        switch (_enumerated(f)) {
          null => '    OBVIOUS',
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
    for (final (:name, :steps) in _parts(tables))
        _module(name,
            extending: 'activation_types_proof',
            body: [
              for (final s in steps) ...[
                for (final (k, row) in s.rows.indexed)
                  _rowTyped(
                    s.action,
                    at: k + 1,
                    row: (
                      picks: row.picks,
                      lets: row.lets,
                      given: [
                        if (_supports[s.place] case final fact? when !s.input)
                          fact.replaceAll('fl[g]', 'fl[f]'),
                        ...row.given,
                      ],
                      clauses: row.clauses,
                    ),
                    definitions: opened,
                  ),
                'LEMMA Fl_${s.action} ==',
                '    ASSUME TypeOK, IndInv, Supports, NEW f \\in Flows, ${s.action}(f)',
                "    PROVE  fl' \\in [Flows -> FlowRecord]",
                '  BY ${[for (var k = 1; k <= s.rows.length; k++) 'FlRow_${s.action}_$k'].join(', ')}',
                '     DEF ${s.action}${s.input ? ', Input' : ''}, Starts, IndInv'
                    '${_supports.containsKey(s.place) && !s.input ? ', Supports' : ''}',
                '',
              ],
            ]),
    _module('activation_types_steps_proof',
        extending: [for (final (:name, steps: _) in _parts(tables)) name].join(', '),
        body: [
          for (final (over, input) in [('TableStep', false), ('InputTableStep', true)]) ...[
            'LEMMA Fl_$over ==',
            '    ASSUME TypeOK, IndInv, Supports, NEW f \\in Flows, $over(f)',
            "    PROVE  fl' \\in [Flows -> FlowRecord]",
            '  BY ${[for (final steps in tables.values) for (final s in steps) if (s.input == input) 'Fl_${s.action}'].join(', ')}',
            '     DEF $over',
            '',
          ],
        ]),
  ];
}

/// The rows one module proves at most: tlapm holds every obligation of a
/// module until it ends, so its memory grows with the module's rows.
const _rowsPerModule = 12;

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
  final assume = [
    'TypeOK',
    r'NEW f \in Flows',
    for (final p in row.picks) 'NEW ${p.name} \\in ${p.from}',
    for (final l in row.lets) ...['NEW ${l.name}', '${l.name} = ${l.to}'],
    ...row.given,
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
  for (final (i, c) in row.clauses.indexed) {
    final m = RegExp(r'^!\[(.+?)\](?:\.(\w+))? = (.*)$').firstMatch(c)!;
    final (index, name, value) = (m[1]!, m[2], m[3]!);
    final field = name == null ? null : FlowField.values.byName(name);
    assert(field != null || value == 'NoFlow', '$action sets a row to $value');
    final before = i == 0 ? 'fl' : 'fl$i';
    clauses.addAll([
      '  <1> DEFINE fl${i + 1} == [$before EXCEPT $c]',
      '  <1>${2 * i + 1}. ($value) \\in ${field?.range ?? 'FlowRecord'}',
      switch (field) {
        null => '    BY NoFlowType',
        final field => '    ${_typed(value, field: field, bound: bound, given: row.given, definitions: definitions, read: read)}',
      },
      '  <1>${2 * i + 2}. fl${i + 1} \\in [Flows -> FlowRecord]',
      '    BY ${i == 0 ? '<1>0' : '<1>${2 * i}'}, <1>${2 * i + 1}, '
          '${field == null ? 'Fl_row' : 'Fl_${field.name}'}'
          '${index == 'f' ? '' : ', <1>s'} DEF fl${i + 1}',
    ]);
  }
  steps.addAll([
    for (final v in ModelVar.values)
      if (read.contains(v)) ...['  <1>${_typeStep(v)}. ${v.type}', '    BY DEF TypeOK'],
    ...clauses,
  ]);
  final n = row.clauses.length;
  return [
    'LEMMA FlRow_${action}_$at ==',
    '    ASSUME ${assume.join(',\n           ')}',
    "    PROVE  fl' \\in [Flows -> FlowRecord]",
    '  <1>0. fl \\in [Flows -> FlowRecord]',
    '    BY DEF TypeOK',
    ...steps,
    "  <1>e. fl' = fl$n",
    '    BY DEF ${[for (var i = 1; i <= n; i++) 'fl$i'].join(', ')}',
    '  <1> QED',
    '    BY <1>${2 * n}, <1>e',
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
    field.range,
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
  final defs = opened;
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

/// What a step needs of its flow beyond `TypeOK`, by the place it runs from,
/// over the flow `g`: true in every reachable state, but not yet proved
/// kept by every step, which a supporting invariant's proof would do. A
/// debt that only shrinks.
const _supports = <String, String>{
  'rLoad': r'fl[g].site \in Sites',
  'tNav': r'fl[g].site \in Sites /\ fl[g].tab \in TabIds',
  'tDupRead': r'fl[g].site \in Sites /\ fl[g].tab \in TabIds',
  'tRemove': r'fl[g].site \in Sites /\ (fl[g].rest = {} => HasFresh(fl[g].site))',
};

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
