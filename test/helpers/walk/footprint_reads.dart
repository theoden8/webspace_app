import 'package:flutter_test/flutter_test.dart';
import '../../formal_model/models.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';

/// What [read] holds beyond [allowed], by step: a variable a step read as
/// it ran that its printed footprint does not name.
Map<ActivationStep, Set<ModelVar>> readsOutside(
  Map<ActivationStep, Set<ModelVar>> read, {
  required Map<ActivationStep, Set<ModelVar>> allowed,
}) => {
  for (final MapEntry(key: step, value: vars) in read.entries)
    if (vars.difference(allowed[step] ?? const {}) case final over
        when over.isNotEmpty)
      step: over,
};

/// The reads a step makes that its printed footprint does not name yet,
/// each with what lifts it. Only shrinks: an entry the footprint now names
/// fails [expectReadsInFootprints].
const owedReads = <ActivationStep, Set<ModelVar>>{
  // A tab flow started by hand at its capture (switchActiveTab, after the
  // input of an open tab or a new tab on a live slot) has no input whose
  // arm prints what the capture records as it begins, so the
  // read lands on the reply. Lifted when those starts are inputs of
  // TabTable.tabInputs.
  ActivationStep.tabCaptureReply: {ModelVar.built},
};

/// Holds what each step of the run read as it ran ([StepReads]) to its
/// printed footprint (`activation_footprints.tsv`), which the schedules'
/// reduction, the footprint gate and the cone decision take as all it
/// reads, and to what its notes declare ([noteReads]), which only the code
/// reads. A read outside both is one they do not see.
void expectReadsInFootprints() {
  final allowed = footprintReads(tables);
  final notes = noteReads(tables);
  expect(
    {
      for (final MapEntry(key: step, value: vars) in owedReads.entries)
        if (vars.intersection(allowed[step] ?? const {}) case final paid
            when paid.isNotEmpty)
          step: paid,
    },
    isEmpty,
    reason: 'a footprint now names what owedReads lists: drop the entry',
  );
  expect(
    readsOutside(
      StepReads.read,
      allowed: {
        for (final MapEntry(key: step, value: vars) in allowed.entries)
          step: {...vars, ...?notes[step], ...?owedReads[step]},
      },
    ),
    isEmpty,
    reason:
        'a step read what its printed footprint does not name: declare '
        'the read where the step reads it',
  );
}
