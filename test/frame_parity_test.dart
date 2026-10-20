import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/formal_model/checks.dart';
import 'package:webspace/formal_model/models.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/model_names.dart';

import 'helpers/walk/frame_declarations.dart';
import 'helpers/walk/frame_values.dart';
import 'helpers/walk/model_frame.dart';

void main() {
  test(
    'every frame slot preserves the keyed comparison for every transition',
    () {
      final values = <Object?>[
        null,
        false,
        0,
        '0',
        (null,),
        FrameValues([1, 2]),
        FrameValues([2, 1]),
      ];
      for (final variable in ModelVar.values) {
        for (final old in values) {
          for (final now in values) {
            final before = {variable: ?old};
            final after = {variable: ?now};
            final expected = {
              for (final key in {...before.keys, ...after.keys})
                if (before[key] != after[key]) key,
            };
            final previous = ModelFrame.capture(read: (v) => before[v]);
            final current = ModelFrame.capture(read: (v) => after[v]);
            expect(current[variable], now);
            expect(
              current.changedSince(previous),
              expected,
              reason: '${variable.name}: $old -> $now',
            );
          }
        }
      }
    },
  );

  test('changes in any two frame slots remain independent', () {
    final before = ModelFrame.capture(read: (v) => v.index);
    for (final first in ModelVar.values) {
      for (final second in ModelVar.values) {
        final after = ModelFrame.capture(
          read: (v) => v == first || v == second ? -1 : v.index,
        );
        expect(after.changedSince(before), {first, second});
      }
    }
  });

  test(
    'snapshots keep independently captured values after source mutation',
    () {
      final source = <Object?>['before'];
      final before = ModelFrame.capture(
        read: (v) => v == ModelVar.tabs ? FrameValues(source) : null,
      );
      source[0] = 'after';
      final after = ModelFrame.capture(
        read: (v) => v == ModelVar.tabs ? FrameValues(source) : null,
      );
      expect(before[ModelVar.tabs], FrameValues(['before']));
      expect(after.changedSince(before), {ModelVar.tabs});
    },
  );

  test(
    'every cached declaration matches its owner, including planted tables',
    () {
      for (final of in [
        null,
        tables,
        for (final m in FrameMistake.values) frameMistake(m),
        for (final m in Mutant.values) mutated(m),
      ]) {
        final cached = FrameDeclarations(of: of);
        expect(FrameDeclarations(of: of), same(cached));
        for (final step in ActivationStep.values) {
          for (final outcome in StepOutcome.values) {
            final expected = declaredWrites(step, outcome: outcome, of: of);
            final actual = cached.writesFor(step, outcome: outcome);
            expect(actual, expected, reason: '${step.name}/${outcome.name}');
            if (actual != null) {
              expect(() => actual.add(ModelVar.rows), throwsUnsupportedError);
            }
          }
        }
      }
    },
  );
}
