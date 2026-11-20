import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/shrunk_tap_target.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ShrunkTapTargetTest);
  });
}

const _ours = r'''
import 'package:flutter/material.dart';
import 'package:mine/mine.dart' as mine;

void tap() {}
Object? label;
// Each library the cases name, used once so no import goes unused.
InkWell? flutter;
mine.Pill? alsoUsed;
''';

@reflectiveTest
class ShrunkTapTargetTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = ShrunkTapTarget();
    newPackage('flutter').addFile('lib/material.dart', r'''
enum MaterialTapTargetSize { padded, shrinkWrap }
class ButtonStyle {}
class TextButton {
  const TextButton({Object? child, Object? onPressed, ButtonStyle? style});
  const TextButton.icon({Object? icon, Object? label, Object? onPressed, ButtonStyle? style});
  static ButtonStyle styleFrom({Object? minimumSize, MaterialTapTargetSize? tapTargetSize}) => ButtonStyle();
}
class Chip {
  const Chip({Object? label, MaterialTapTargetSize? materialTapTargetSize});
}
class ActionChip {
  const ActionChip({Object? label, Object? onPressed, MaterialTapTargetSize? materialTapTargetSize});
}
class InkWell {
  const InkWell({Object? child, Object? onTap});
}
''');
    newPackage('mine').addFile('lib/mine.dart', r'''
enum MaterialTapTargetSize { padded, shrinkWrap }
class Pill {
  const Pill({Object? onPressed, MaterialTapTargetSize? size});
}
''');
    super.setUp();
  }

  String _case(String body) => '''
$_ours
void build() {
  $body
}
''';

  Future<void> _ok(String body) => assertNoDiagnostics(_case(body));

  Future<void> _caught(String body, {required String widget}) async {
    final source = _case(body);
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    final length = source.indexOf('/*end*/') - at;
    await assertDiagnostics(source, [
      lint(at, length, messageContainsAll: ['A tappable $widget shrinks']),
    ]);
  }

  // The drawer's back row before its fix.
  Future<void> test_a_button_style_that_shrinks_the_target() => _caught(
    'final b = TextButton.icon(onPressed: tap, label: label, '
    'style: TextButton.styleFrom(tapTargetSize: '
    '/*here*/MaterialTapTargetSize.shrinkWrap/*end*/));',
    widget: 'TextButton',
  );

  Future<void> test_a_tappable_chip_that_shrinks() => _caught(
    'final c = ActionChip(label: label, onPressed: tap, '
    'materialTapTargetSize: /*here*/MaterialTapTargetSize.shrinkWrap/*end*/);',
    widget: 'ActionChip',
  );

  Future<void> test_a_label_chip_nothing_taps() => _ok(
    'final c = Chip(label: label, '
    'materialTapTargetSize: MaterialTapTargetSize.shrinkWrap);',
  );

  Future<void> test_a_disabled_button() => _ok(
    'final b = TextButton(onPressed: null, '
    'style: TextButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap));',
  );

  Future<void> test_the_padded_target() => _ok(
    'final b = TextButton(onPressed: tap, '
    'style: TextButton.styleFrom(tapTargetSize: MaterialTapTargetSize.padded));',
  );

  Future<void> test_a_style_kept_apart_from_a_button() => _ok(
    'final s = TextButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap);',
  );

  Future<void> test_a_look_alike_outside_flutter() => _ok(
    'final p = mine.Pill(onPressed: tap, size: mine.MaterialTapTargetSize.shrinkWrap);',
  );
}
