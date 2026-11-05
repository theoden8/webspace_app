import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';

import 'formal_model/models.dart';

/// The steps of [table] whose declared writes, for any outcome they can end
/// with, take in [variable].
Set<ActivationStep> _writers(StepTable<Object?, Enum> table,
        {required ModelVar variable}) =>
    {
      for (final (:step, place: _) in table.steps)
        for (final outcome in step.name.outcomes)
          if (declaredWrites(step.name, outcome: outcome)
                  ?.contains(variable) ??
              false)
            step.name,
    };

void main() {
  // The runner holds each step to the variables its arm declares, and the
  // walks hold the code between two awaits to them, so a tab list the
  // activation's code changed would have to be declared, where this sees it.
  // That a loaded site at rest shows its active tab is Inv_TabActive's.
  test(
      'TAB-004: no step of an activation (a tap, a preload, Home, a share '
      'arriving) or of the unloads it runs writes a site\'s tab list', () {
    for (final (name, table) in [
      ('activation', tables.activation),
      ('unload', tables.unload),
      ('jar', tables.jar),
      ('restore', tables.restore),
    ]) {
      expect(_writers(table, variable: ModelVar.tabs), isEmpty, reason: name);
    }
  });

  test('TAB-004: the tab flow, where tabs are made, is what the check names',
      () {
    expect(
        _writers(tables.tabFlow, variable: ModelVar.tabs),
        containsAll(<ActivationStep>[
          ActivationStep.tabRebind,
          ActivationStep.dupInsert,
        ]));
  });
}
