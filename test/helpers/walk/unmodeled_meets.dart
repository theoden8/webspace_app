import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';

/// The steps that may read, once their await is over, what a write no step
/// takes changed meanwhile ([UnmodeledWrites]): each a timing TLC did not
/// check, owed here with why. A meet not listed fails the run.
///
/// A slot that runs as another site leaves the loaded sites in the reroute
/// world (LIR-024), whose traces are not replayed: the model keeps no slot
/// identity (`steps_uncovered.tsv`). Within two preemptions an activation's
/// or a going home's step reads `loaded` across it.
const owedMeets = <UnmodeledMeet>{
  (
    step: ActivationStep.navReply,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.unloadNavReply,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.unloadNavSave,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.quiesceReply,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.contReply,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.cacheReply,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.resumeReply,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.homeCapture,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.homeCaptureSave,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
  (
    step: ActivationStep.homeQuiesceReply,
    by: Unmodeled.identityChange,
    variable: ModelVar.loaded,
  ),
};

/// Holds what the run met to [owedMeets] (Phase 4: a step's reads checked
/// at its commit).
void expectOnlyOwedMeets() => expect(
  UnmodeledWrites.met.difference(owedMeets),
  isEmpty,
  reason:
      'a step read what a write no step takes changed while it waited: '
      'take the write in a step, or owe the meet here with why',
);
