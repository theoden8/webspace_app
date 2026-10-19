import 'package:webspace/services/model_names.dart';

/// An immutable frame with one slot per declared model variable, including
/// null for variables only the model holds; no separate key registry can drift.
final class ModelFrame {
  ModelFrame.capture({required Object? Function(ModelVar) read})
    : _values = List<Object?>.generate(
        ModelVar.values.length,
        (i) => read(ModelVar.values[i]),
        growable: false,
      );

  final List<Object?> _values;

  Object? operator [](ModelVar variable) => _values[variable.index];

  Set<ModelVar> changedSince(ModelFrame before) => {
    for (final variable in ModelVar.values)
      if (before._values[variable.index] != _values[variable.index]) variable,
  };
}
