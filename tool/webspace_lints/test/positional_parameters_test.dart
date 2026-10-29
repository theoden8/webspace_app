import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/positional_parameters.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PositionalParametersTest);
  });
}

@reflectiveTest
class PositionalParametersTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = PositionalParameters();
    newPackage('outside').addFile('lib/outside.dart', r'''
typedef ValueChanged<T> = void Function(T value);
void listen(void Function(int a, int b) callback) {}
abstract class Base {
  void m(int a, int b);
}
''');
    super.setUp();
  }

  Future<void> test_two_positional() async {
    await assertDiagnostics(
      r'''
void f(int a, int b) {}
''',
      [
        lint(6, 14, messageContainsAll: ["'f'", '2 positional']),
      ],
    );
  }

  Future<void> test_one_positional_then_named() async {
    await assertNoDiagnostics(r'''
void f(int a, {required int b}) {}
''');
  }

  Future<void> test_positional_bool_first() async {
    await assertDiagnostics(
      r'''
void f(bool on) {}
''',
      [
        lint(6, 9, messageContainsAll: ['positional bool on']),
      ],
    );
  }

  Future<void> test_optional_positional_bool() async {
    await assertDiagnostics(
      r'''
void f([bool? on]) {}
''',
      [lint(6, 12)],
    );
  }

  Future<void> test_field_formal_bool() async {
    await assertDiagnostics(
      r'''
class C {
  C(this.on);
  final bool on;
}
''',
      [
        lint(13, 9, messageContainsAll: ["'C'"]),
      ],
    );
  }

  Future<void> test_named_bool() async {
    await assertNoDiagnostics(r'''
void f({required bool on}) {}
''');
  }

  Future<void> test_method() async {
    await assertDiagnostics(
      r'''
class C {
  void m(int a, int b) {}
}
''',
      [
        lint(18, 14, messageContainsAll: ["'m'"]),
      ],
    );
  }

  Future<void> test_named_constructor() async {
    await assertDiagnostics(
      r'''
class C {
  C.at(int a, int b);
}
''',
      [
        lint(16, 14, messageContainsAll: ["'C.at'"]),
      ],
    );
  }

  Future<void> test_function_type() async {
    await assertDiagnostics(
      r'''
void f({required void Function(int, int) g}) {}
''',
      [
        lint(30, 10, messageContainsAll: ["'Function type'"]),
      ],
    );
  }

  Future<void> test_typedef() async {
    await assertDiagnostics(
      r'''
typedef F = void Function(int a, int b);
''',
      [
        lint(25, 14, messageContainsAll: ["'F'"]),
      ],
    );
  }

  Future<void> test_old_style_typedef() async {
    await assertDiagnostics(
      r'''
typedef void F(int a, int b);
''',
      [
        lint(14, 14, messageContainsAll: ["'F'"]),
      ],
    );
  }

  Future<void> test_function_typed_parameter() async {
    await assertDiagnostics(
      r'''
void f({required void g(int a, int b)}) {}
''',
      [
        lint(23, 14, messageContainsAll: ['g (function-typed parameter)']),
      ],
    );
  }

  Future<void> test_override_is_fixed_from_outside() async {
    await assertNoDiagnostics(r'''
import 'package:outside/outside.dart';
class C extends Base {
  @override
  void m(int a, int b) {}
}
''');
  }

  Future<void> test_operator_setter_main_closure() async {
    await assertNoDiagnostics(r'''
class C {
  int operator +(int other) => other;
  set on(bool value) {}
}
void main(List<String> args, Object? message) {
  final g = (int a, int b) => a + b;
  g(1, 2);
}
''');
  }

  Future<void> test_torn_off_into_the_sdk() async {
    await assertNoDiagnostics(r'''
void _visit(String key, int value) {}
void f(Map<String, int> m) => m.forEach(_visit);
''');
  }

  Future<void> test_torn_off_into_a_parameter_outside() async {
    await assertNoDiagnostics(r'''
import 'package:outside/outside.dart';
void _both(int a, int b) {}
void f() => listen(_both);
''');
  }

  Future<void> test_torn_off_as_a_typedef_from_outside() async {
    await assertNoDiagnostics(r'''
import 'package:outside/outside.dart';
class Toggle {
  Toggle({required this.onChanged});
  final ValueChanged<bool> onChanged;
}
class C {
  void _set(bool value) {}
  Toggle build() => Toggle(onChanged: _set);
}
''');
  }

  Future<void> test_torn_off_into_our_own_type() async {
    await assertDiagnostics(
      r'''
typedef Mine = void Function(int a);
void take({required Mine g}) {}
void _both(int a, int b) {}
void _one(bool on) {}
void f() => take(g: (a) => _both(a, a));
void h() => take(g: (_) => _one(true));
''',
      [lint(79, 14), lint(106, 9)],
    );
  }

  Future<void> test_called_not_torn_off() async {
    await assertDiagnostics(
      r'''
void _visit(String key, int value) {}
void f(Map<String, int> m) => m.forEach((k, v) => _visit(k, v));
''',
      [lint(11, 23)],
    );
  }

  Future<void> test_native_binding() async {
    await assertNoDiagnostics(r'''
import 'dart:ffi';
typedef _AddC = Int32 Function(Int32 a, Int32 b);
typedef _AddDart = int Function(int a, int b);
int f(DynamicLibrary lib) =>
    lib.lookupFunction<_AddC, _AddDart>('add')(1, 2);
''');
  }

  Future<void> test_native_function_inline() async {
    await assertNoDiagnostics(r'''
import 'dart:ffi';
void f(Pointer<NativeFunction<Int32 Function(Int32, Int32)>> p) {}
''');
  }
}
