import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/unnamed_button.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(UnnamedButtonTest);
  });
}

/// The cases' declarations; `mine` holds a button of the same name that is
/// not Flutter's, which the rule leaves to its owner.
const _ours = r'''
import 'package:flutter/material.dart';
import 'package:mine/mine.dart' as mine;

Object? icon;
IconButton? used;
mine.IconButton? alsoUsed;
''';

@reflectiveTest
class UnnamedButtonTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = UnnamedButton();
    newPackage('flutter').addFile('lib/material.dart', r'''
class IconButton {
  const IconButton({Object? icon, String? tooltip, Object? onPressed});
  const IconButton.filled({Object? icon, String? tooltip, Object? onPressed});
  static Object styleFrom({Object? padding}) => 0;
}
class FloatingActionButton {
  const FloatingActionButton({Object? child, String? tooltip, Object? onPressed});
  const FloatingActionButton.extended({Object? label, Object? icon, Object? onPressed});
}
''');
    newPackage('mine').addFile('lib/mine.dart', r'''
class IconButton {
  IconButton({Object? icon});
}
''');
    super.setUp();
  }

  String _case(String body) =>
      '''
$_ours
String name() => 'Add';
void run() {
  $body
}
''';

  Future<void> _ok(String body) => assertNoDiagnostics(_case(body));

  Future<void> _caught(String body, {required String made}) async {
    final source = _case(body);
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    final length = source.indexOf('/*end*/') - at;
    await assertDiagnostics(source, [
      lint(at, length, messageContainsAll: ["'$made' shows only an icon"]),
    ]);
  }

  Future<void> test_icon_button_without_a_tooltip() => _caught(
    'final b = /*here*/IconButton/*end*/(icon: icon, onPressed: null);',
    made: 'IconButton',
  );

  Future<void> test_a_named_constructor_without_a_tooltip() => _caught(
    'final b = /*here*/IconButton.filled/*end*/(icon: icon);',
    made: 'IconButton',
  );

  Future<void> test_a_tooltip_of_null() => _caught(
    'final b = /*here*/IconButton/*end*/(icon: icon, tooltip: null);',
    made: 'IconButton',
  );

  Future<void> test_a_fab_without_a_tooltip() => _caught(
    'final b = /*here*/FloatingActionButton/*end*/(child: icon);',
    made: 'FloatingActionButton',
  );

  Future<void> test_a_const_button_without_a_tooltip() => _caught(
    'const b = /*here*/IconButton/*end*/(icon: null);',
    made: 'IconButton',
  );

  Future<void> test_icon_button_with_a_tooltip() =>
      _ok('final b = IconButton(icon: icon, tooltip: name());');

  Future<void> test_a_fab_with_a_tooltip() =>
      _ok('final b = FloatingActionButton(child: icon, tooltip: name());');

  Future<void> test_an_extended_fab_shows_its_label() =>
      _ok('final b = FloatingActionButton.extended(label: icon, icon: icon);');

  Future<void> test_style_from_is_no_button() =>
      _ok('final s = IconButton.styleFrom(padding: null);');

  Future<void> test_a_look_alike_outside_flutter() =>
      _ok('final b = mine.IconButton(icon: icon);');
}
