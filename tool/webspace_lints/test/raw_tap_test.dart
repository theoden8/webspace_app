import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/raw_tap.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(RawTapTest);
  });
}

/// The cases' declarations; `mine` holds a `Listener` and a `Semantics` of
/// the same names that are not Flutter's, which the rule leaves alone.
const _ours = r'''
import 'package:flutter/widgets.dart';
import 'package:mine/mine.dart' as mine;

Object? child;
void tap() {}
Listener? used;
mine.Listener? alsoUsed;
''';

@reflectiveTest
class RawTapTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = RawTap();
    newPackage('flutter').addFile('lib/widgets.dart', r'''
class Listener {
  const Listener({Object? onPointerDown, Object? onPointerUp, Object? child});
}
class Semantics {
  const Semantics({bool? button, Object? onTap, Object? child});
}
class Builder {
  const Builder({required Object Function(Object context) builder});
}
''');
    newPackage('mine').addFile('lib/mine.dart', r'''
class Listener {
  Listener({Object? onPointerUp, Object? child});
}
class Semantics {
  Semantics({Object? onTap, Object? child});
}
''');
    super.setUp();
  }

  String _case(String body) =>
      '''
$_ours
Object build() {
  $body
}
''';

  Future<void> _ok(String body) => assertNoDiagnostics(_case(body));

  Future<void> _caught(String body) async {
    final source = _case(body);
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    final length = source.indexOf('/*end*/') - at;
    await assertDiagnostics(source, [
      lint(at, length, messageContainsAll: ['raw pointer up']),
    ]);
  }

  Future<void> test_a_bare_raw_tap() => _caught(
    'return /*here*/Listener/*end*/(onPointerUp: (_) => tap(), child: child);',
  );

  Future<void> test_a_semantics_with_no_tap() => _caught(
    'return Semantics(button: true, '
    'child: /*here*/Listener/*end*/(onPointerUp: (_) => tap()));',
  );

  Future<void> test_a_semantics_tap_of_null() => _caught(
    'return Semantics(onTap: null, '
    'child: /*here*/Listener/*end*/(onPointerUp: (_) => tap()));',
  );

  Future<void> test_a_semantics_in_another_build() => _caught(
    'final inner = /*here*/Listener/*end*/(onPointerUp: (_) => tap()); '
    'return inner;',
  );

  Future<void> test_a_look_alike_semantics() => _caught(
    'return mine.Semantics(onTap: tap, '
    'child: /*here*/Listener/*end*/(onPointerUp: (_) => tap()));',
  );

  Future<void> test_a_semantics_tap_around_it() => _ok(
    'return Semantics(onTap: tap, '
    'child: Listener(onPointerUp: (_) => tap(), child: child));',
  );

  Future<void> test_a_semantics_tap_across_a_builder() => _ok(
    'return Semantics(onTap: tap, child: Builder(builder: (context) => '
    'Listener(onPointerUp: (_) => tap())));',
  );

  Future<void> test_a_listener_with_no_pointer_up() =>
      _ok('return Listener(onPointerDown: (_) => tap(), child: child);');

  Future<void> test_a_look_alike_listener() =>
      _ok('return mine.Listener(onPointerUp: (_) => tap());');
}
