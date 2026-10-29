import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/held_in_turn.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(HeldInTurnTest);
  });
}

/// The queue and the annotation, as `lib/utils/concurrency.dart` declares
/// them.
const _concurrency = r'''
final class SerialQueue {
  SerialQueue(this.name);
  final String name;
  Future<T> run<T>(Future<T> Function() task) => task();
  void enqueue(Future<void> Function() task) {}
}

final class Held {
  const Held(this.queue);
  final Symbol queue;
}
''';

@reflectiveTest
class HeldInTurnTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = HeldInTurn();
    super.setUp();
    newFile('$testPackageLibPath/concurrency.dart', _concurrency);
  }

  Future<void> _ok(String body) => assertNoDiagnostics('''
import 'concurrency.dart';
class C {
  final _ops = SerialQueue('ops');
  final _other = SerialQueue('other');
  @Held(#_ops)
  Future<void> _saveHeld() async {}
  @Held(#_ops)
  int _countHeld() => 0;
$body
}
''');

  Future<void> _caught(String body, {required String message}) async {
    final source =
        '''
import 'concurrency.dart';
class C {
  final _ops = SerialQueue('ops');
  final _other = SerialQueue('other');
  @Held(#_ops)
  Future<void> _saveHeld() async {}
  @Held(#_ops)
  int _countHeld() => 0;
$body
}
''';
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    final length = RegExp(r'_\w+Held').matchAsPrefix(source, at)!.end - at;
    await assertDiagnostics(source, [
      lint(at, length, messageContainsAll: [message]),
    ]);
  }

  Future<void> test_from_its_queues_run() =>
      _ok('Future<void> save() => _ops.run(() => _saveHeld());');

  Future<void> test_awaited_in_an_async_task() =>
      _ok('Future<void> save() => _ops.run(() async { await _saveHeld(); });');

  Future<void> test_from_its_queues_enqueue() =>
      _ok('void save() => _ops.enqueue(() => _saveHeld());');

  Future<void> test_from_another_member_held_in_it() => _ok('''
  @Held(#_ops)
  Future<void> _bothHeld() async {
    await _saveHeld();
    _countHeld();
  }
''');

  Future<void> test_through_this() =>
      _ok('Future<void> save() => this._ops.run(() => this._saveHeld());');

  Future<void> test_torn_off_as_the_task() =>
      _ok('Future<void> save() => _ops.run(_saveHeld);');

  Future<void> test_outside_any_turn() => _caught(
    'Future<void> save() => /*here*/_saveHeld();',
    message: "'_saveHeld' runs in _ops's turn",
  );

  Future<void> test_sync_member_outside() => _caught(
    'int count() => /*here*/_countHeld();',
    message: "'_countHeld' runs in _ops's turn",
  );

  Future<void> test_in_another_queues_turn() => _caught(
    'Future<void> save() => _other.run(() => /*here*/_saveHeld());',
    message: "'_saveHeld' runs in _ops's turn",
  );

  Future<void> test_in_a_closure_that_escapes_the_task() => _caught('''
  Future<void> save() => _ops.run(() async {
    Future<void>.delayed(Duration.zero, () => /*here*/_saveHeld());
  });
''', message: "'_saveHeld' runs in _ops's turn");

  Future<void> test_in_a_member_held_in_another_queue() => _caught('''
  @Held(#_other)
  Future<void> _elsewhereHeld() => /*here*/_saveHeld();
''', message: "'_saveHeld' runs in _ops's turn");

  Future<void> test_on_another_object() => _caught(
    'Future<void> save(C c) => _ops.run(() => c./*here*/_saveHeld());',
    message: "'_saveHeld' runs in _ops's turn",
  );

  Future<void> test_torn_off_elsewhere() => _caught(
    'Future<void> Function() later() => /*here*/_saveHeld;',
    message: "'_saveHeld' runs in _ops's turn",
  );

  Future<void> test_future_dropped_in_the_turn() => _caught('''
  @Held(#_ops)
  Future<void> _bothHeld() async {
    /*here*/_saveHeld();
  }
''', message: "_ops's turn can end before '_saveHeld' does");

  Future<void> test_names_no_queue() async {
    await assertDiagnostics(
      r'''
import 'concurrency.dart';
class C {
  final _count = 0;
  @Held(#_count)
  void _countHeld() {}
  @Held(#_nothing)
  void _nothingHeld() {}
}
''',
      [
        lint(59, 14, messageContainsAll: ["'_count' names no SerialQueue"]),
        lint(99, 16, messageContainsAll: ["'_nothing' names no SerialQueue"]),
      ],
    );
  }

  Future<void> test_a_top_level_queue() async {
    await assertNoDiagnostics(r'''
import 'concurrency.dart';
final _ops = SerialQueue('ops');
@Held(#_ops)
Future<void> _saveHeld() async {}
Future<void> save() => _ops.run(() => _saveHeld());
''');
  }
}
