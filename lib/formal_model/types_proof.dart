import 'package:webspace/services/model_names.dart';

/// The typing lemmas a proof that every step keeps `TypeOK` rests on,
/// printed from the flow's fields: a function of flow records updated in
/// one field of one row, with a value in that field's range, is still one
/// (`Fl_<field>`), and `NoFlow` is a flow record, field by field, since the
/// provers do not take a record set of every field whole.
String activationTypesProof() => [
  '---------------------- MODULE activation_types_proof ----------------------',
  '(* Printed from FlowField by lib/formal_model/main.dart.                 *)',
  '(* Not committed; edit the declarations instead.                          *)',
  'EXTENDS activation',
  '',
  for (final f in FlowField.values) ...[
    'LEMMA Fl_${f.name} ==',
    '    ASSUME NEW g \\in [Flows -> FlowRecord], NEW x \\in Flows,',
    '           NEW val \\in ${f.range}',
    '    PROVE  [g EXCEPT ![x].${f.name} = val] \\in [Flows -> FlowRecord]',
    '  BY DEF FlowRecord',
    '',
  ],
  'LEMMA NoFlowType == NoFlow \\in FlowRecord',
  '  <1> USE DEF NoFlow, FlowKinds, Places',
  for (final (i, f) in FlowField.values.indexed) ...[
    '  <1>${i + 1}. NoFlow.${f.name} \\in ${f.range}',
    '    OBVIOUS',
  ],
  '  <1> QED',
  '    BY ${[for (var i = 1; i <= FlowField.values.length; i++) '<1>$i'].join(', ')}',
  '       DEF FlowRecord',
  '',
  '=' * 77,
  '',
].join('\n');
