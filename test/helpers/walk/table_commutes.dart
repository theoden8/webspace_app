import '../../formal_model/models.dart';
import '../../formal_model/worlds.dart';
import 'package:webspace/services/activation_step.dart';

/// Whether two steps run in either order to one state, as the tables
/// declare them: no variable shared between their actions, by the relation
/// the printer pairs actions with ([shared]). A step no table holds (one
/// the code or the walk marks by hand: the environment's moves, frames,
/// logins and the jar's clear) commutes with none, so a search is reduced
/// only where the footprints are known.
bool tableCommutes(ActivationStep a, {required ActivationStep other}) =>
    _commutes[a.index * _steps + other.index];

final _steps = ActivationStep.values.length;

final List<bool> _commutes = () {
  final byStep = <ActivationStep, List<ComposedAction>>{};
  for (final (:step, :action) in stepActions(tables)) {
    (byStep[step] ??= []).add(action);
  }
  return [
    for (final a in ActivationStep.values)
      for (final b in ActivationStep.values)
        switch ((byStep[a], byStep[b])) {
          (final x?, final y?) => x.every(
            (p) => y.every((q) => shared(p, other: q).isEmpty),
          ),
          _ => false,
        },
  ];
}();
