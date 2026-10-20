import 'package:webspace/formal_model/models.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/model_names.dart';

/// Immutable write declarations derived once from the owning tables for every
/// step/outcome pair, so frame checks need no table scan or set construction.
final class FrameDeclarations {
  factory FrameDeclarations({Tables? of}) {
    if (of == null || of == tables) return _standard;
    return _custom.putIfAbsent(of, () => FrameDeclarations._(of: of));
  }

  FrameDeclarations._({Tables? of})
    : _writes = [
        for (final step in ActivationStep.values)
          [
            for (final outcome in StepOutcome.values)
              switch (declaredWrites(step, outcome: outcome, of: of)) {
                null => null,
                final variables => Set<ModelVar>.unmodifiable(variables),
              },
          ],
      ];

  static final _standard = FrameDeclarations._();
  static final _custom = <Tables, FrameDeclarations>{};

  final List<List<Set<ModelVar>?>> _writes;

  Set<ModelVar>? writesFor(
    ActivationStep step, {
    required StepOutcome outcome,
  }) => _writes[step.index][outcome.index];
}
