import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The labels of the custom actions the one node [finder] finds offers, as a
/// screen reader lists them; a hint that overrides a standard action's is
/// none.
Set<String> customActionsOf(SemanticsFinder finder) => {
  for (final id
      in finder.evaluate().single.getSemanticsData().customSemanticsActionIds ??
          const <int>[])
    if (CustomSemanticsAction.getAction(id)
        case CustomSemanticsAction(label: final label?))
      label,
};

/// Chooses the custom action [label] on the one node [finder] finds, as a
/// screen reader does from its actions menu.
void performCustomAction(SemanticsFinder finder, {required String label}) {
  final node = finder.evaluate().single;
  node.owner!.performAction(
    node.id,
    SemanticsAction.customAction,
    CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label)),
  );
}

/// The node a screen reader focuses and presses for the control named
/// [name]: its label, or for a button named by its tooltip the tooltip,
/// starts with [name], it has a tap, and it is not merged into another node.
SemanticsFinder pressable(String name) => find.semantics.byPredicate(
  (node) =>
      !node.isMergedIntoParent &&
      (node.label.startsWith(name) || node.tooltip.startsWith(name)) &&
      node.getSemanticsData().hasAction(SemanticsAction.tap),
  describeMatch: (_) => 'the control named $name',
);
