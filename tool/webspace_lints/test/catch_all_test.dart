import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/catch_all.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchAllTest);
  });
}

/// The declarations the cases call, outside the code under test.
const _calls = r'''
import 'dart:async';
final class SocketFailure implements Exception {}
final class TimedOut implements Exception {}
abstract class IoFailure implements Exception {}
final class ParseFailure implements Exception {
  const ParseFailure(this.message);
  final String message;
}
void f() {}
Future<int> g() async => 0;
late final Stream<int> s;
void log(Object e) {}
Never fail(Object e) => throw e;
''';

/// `Future.onError`, as dart:async declares it; the mock SDK leaves it out.
const _onError = r'''
extension FutureExtensions<T> on Future<T> {
  Future<T> onError<E extends Object>(
    FutureOr<T> handleError(E error, StackTrace stackTrace), {
    bool test(E error)?,
  }) => this;
}
''';

@reflectiveTest
class CatchAllTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = CatchAll();
    super.setUp();
    final async = sdkRoot.getFolder('lib').getFile('async/async.dart');
    newFile(async.path, '${async.readAsStringSync()}$_onError');
  }

  /// The source of a case, with `/*here*/` before what it reports.
  String _case(String body) =>
      '''
$_calls
void run() {
  $body
}
''';

  Future<void> _ok(String body) => assertNoDiagnostics(_case(body));

  Future<void> _caught(
    String body, {
    required int length,
    required String message,
  }) async {
    final source = _case(body);
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    await assertDiagnostics(source, [
      lint(at, length, messageContainsAll: [message]),
    ]);
  }

  Future<void> test_on_exception() => _caught(
    'try { f(); } on /*here*/Exception { }',
    length: 'Exception'.length,
    message: "'Exception' names no failure",
  );

  Future<void> test_on_exception_with_catch() => _caught(
    'try { f(); } on /*here*/Exception catch (e) { log(e); }',
    length: 'Exception'.length,
    message: "'Exception' names no failure",
  );

  Future<void> test_on_object_after_a_typed_clause() => _caught(
    'try { f(); } on ParseFailure { } on /*here*/Object catch (e) { log(e); }',
    length: 'Object'.length,
    message: "'Object' names no failure",
  );

  Future<void> test_on_error() => _caught(
    'try { f(); } on /*here*/Error catch (e) { log(e); }',
    length: 'Error'.length,
    message: "'Error' names no failure",
  );

  Future<void> test_on_an_alias_of_exception() async {
    const source =
        '''
$_calls
typedef Failure = Exception;
void run() {
  try { f(); } on /*here*/Failure { }
}
''';
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    await assertDiagnostics(source, [
      lint(at, 'Failure'.length, messageContainsAll: ["'Exception'"]),
    ]);
  }

  Future<void> test_on_a_type_parameter_its_caller_names() async {
    await assertNoDiagnostics('''
$_calls
Future<bool> refuses<E extends Object>(Future<void> call) async {
  try {
    await call;
    return false;
  } on E {
    return true;
  }
}
''');
  }

  Future<void> test_catch_error_with_a_generic_test() => _caught(
    'unawaited(g().catchError((Object _) => 0, test: (e) => /*here*/e is Exception));',
    length: 'e is Exception'.length,
    message: "'Exception' names no failure",
  );

  Future<void>
  test_catch_error_with_a_typed_parameter_and_a_generic_test() => _caught(
    'unawaited(g().catchError((Object _) => 0, test: (Object e) => /*here*/e is Exception));',
    length: 'e is Exception'.length,
    message: "'Exception' names no failure",
  );

  Future<void> test_catch_error_with_a_test_admitting_one_generic() => _caught(
    'unawaited(g().catchError((Object _) => 0, test: (e) => e is SocketFailure || /*here*/e is Error));',
    length: 'e is Error'.length,
    message: "'Error' names no failure",
  );

  Future<void> test_catch_error_with_a_test_admitting_everything() => _caught(
    'unawaited(g().catchError((Object _) => 0, test: (e) => /*here*/true));',
    length: 'true'.length,
    message: "'true' names no failure",
  );

  Future<void> test_catch_error_without_test() => _caught(
    'unawaited(g()./*here*/catchError((Object e) => 0));',
    length: 'catchError'.length,
    message: "This 'catchError' has no test:",
  );

  Future<void> test_handle_error_without_test() => _caught(
    's./*here*/handleError((Object _) {});',
    length: 'handleError'.length,
    message: "This 'handleError' has no test:",
  );

  Future<void> test_listen_dropping_the_error() => _caught(
    's.listen(log, onError: /*here*/(Object _) {});',
    length: '(Object _) {}'.length,
    message: 'drops its error',
  );

  Future<void> test_listen_dropping_an_untyped_error() => _caught(
    's.listen(log, onError: /*here*/(_) => f());',
    length: '(_) => f()'.length,
    message: 'drops its error',
  );

  Future<void> test_listen_naming_the_error_and_not_reading_it() => _caught(
    's.listen(log, onError: /*here*/(Object e) => f());',
    length: '(Object e) => f()'.length,
    message: 'drops its error',
  );

  Future<void> test_then_dropping_the_error() => _caught(
    'unawaited(g().then(log, onError: /*here*/(Object _, StackTrace _) => 0));',
    length: '(Object _, StackTrace _) => 0'.length,
    message: 'drops its error',
  );

  Future<void> test_subscription_on_error_dropping_it() => _caught(
    's.listen(log).onError(/*here*/(Object _) {});',
    length: '(Object _) {}'.length,
    message: 'drops its error',
  );

  Future<void> test_on_error_of_a_generic_type() => _caught(
    'unawaited(g().onError/*here*/<Exception>((e, st) => 0));',
    length: '<Exception>'.length,
    message: "'Exception' names no failure",
  );

  Future<void> test_on_error_inferring_object() => _caught(
    'unawaited(g()./*here*/onError((Object e, StackTrace st) => 0));',
    length: 'onError'.length,
    message: "'Object' names no failure",
  );

  Future<void> test_on_error_with_a_generic_test() => _caught(
    'unawaited(g().onError<Object>((e, st) => 0, test: (e) => /*here*/e is Exception));',
    length: 'e is Exception'.length,
    message: "'Exception' names no failure",
  );

  Future<void> test_subscription_on_error_in_a_cascade_dropping_it() => _caught(
    's.listen(log)..onError(/*here*/(Object _) {});',
    length: '(Object _) {}'.length,
    message: 'drops its error',
  );

  Future<void> test_a_plain_exception() => _caught(
    "throw /*here*/Exception('List not found');",
    length: "Exception('List not found')".length,
    message: 'A plain Exception',
  );

  Future<void> test_a_plain_exception_with_a_stack() => _caught(
    "fail(/*here*/Exception('x'));",
    length: "Exception('x')".length,
    message: 'A plain Exception',
  );

  Future<void> test_typed_on_clauses() => _ok(
    'try { f(); } on SocketFailure catch (e) { log(e); } on ParseFailure { }',
  );

  Future<void> test_a_family_its_library_declares() =>
      _ok('try { f(); } on IoFailure { }');

  Future<void> test_catch_error_with_a_typed_test() => _ok(
    'unawaited(g().catchError((Object _) => 0, test: (e) => e is TimedOut));',
  );

  Future<void> test_handle_error_with_a_typed_test() =>
      _ok('s.handleError((Object _) {}, test: (e) => e is SocketFailure);');

  Future<void> test_listen_handing_the_error_on() => _ok('''
    final done = Completer<void>();
    s.listen(log, onError: (Object e, StackTrace st) => done.completeError(e, st));
''');

  Future<void> test_listen_handing_on_a_torn_off_handler() => _ok('''
    final done = Completer<void>();
    s.listen(log, onError: done.completeError);
''');

  Future<void> test_subscription_on_error_handing_it_on() => _ok('''
    final done = Completer<void>();
    s.listen(log).onError((Object e, StackTrace st) => done.completeError(e, st));
''');

  Future<void> test_on_error_of_a_named_type() =>
      _ok('unawaited(g().onError<SocketFailure>((e, st) => 0));');

  Future<void> test_on_error_of_a_generic_type_with_a_typed_test() => _ok(
    'unawaited(g().onError<Exception>((e, st) => 0, test: (e) => e is TimedOut));',
  );

  Future<void> test_a_typed_throw() => _ok("throw const ParseFailure('bad');");

  Future<void> test_a_type_of_ours_implementing_exception() async {
    await assertNoDiagnostics('''
final class Refused implements Exception {}
void run() => throw Refused();
''');
  }

  Future<void> test_extension_and_mixin_on_object() async {
    await assertNoDiagnostics('''
extension X on Object {}
mixin M on Object {}
''');
  }

  Future<void> test_a_string_or_comment_naming_one() => _ok('''
    // } on Exception {
    log('try { } on Exception { }');
''');

  Future<void> test_a_look_alike_catch_error_of_ours() async {
    await assertNoDiagnostics('''
class Q {
  void catchError(void Function(Object) handler) {}
}
void run() => Q().catchError((Object _) {});
''');
  }
}
