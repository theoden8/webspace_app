import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/model_await.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ModelAwaitTest);
  });
}

/// The cells and the turn, as `lib/services/step_table.dart` declares them.
const _stepTable = r'''
final class Shared<T> {
  Shared(this._value);
  final T _value;
  T get value => _value;
}

final class Commit {
  const Commit.unmodeled();
}

void commitInput({required void Function(Commit) writes}) {}
''';

/// The annotation, as `lib/services/model_names.dart` declares it, and a
/// runtime that reads through it.
const _sites = r'''
import 'step_table.dart';

enum ModelVar { loaded, current }

final class Modeled {
  const Modeled(this.variable);
  final ModelVar variable;
}

class Site {
  void dispose({required Commit commit}) {}
}

class Sites {
  @Modeled(ModelVar.loaded)
  List<Site> get loaded => [];
  @Modeled(ModelVar.current)
  Site? get shown => null;
  final version = Shared(0);
}

Future<void> pause() async {}
''';

@reflectiveTest
class ModelAwaitTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = ModelAwait();
    super.setUp();
    newFile('$testPackageLibPath/step_table.dart', _stepTable);
    newFile('$testPackageLibPath/sites.dart', _sites);
  }

  static String _source(String body) =>
      '''
import 'step_table.dart';
import 'sites.dart';
const drop = Commit.unmodeled();
void log(Object? o) {}
class Failed implements Exception {}
$body
''';

  Future<void> _ok(String body) => assertNoDiagnostics(_source(body));

  /// [body] marks the await the hold crosses with `/*here*/`, followed by
  /// [node], the text reported.
  Future<void> _caught(
    String body, {
    required String read,
    required String written,
    String node = 'await pause()',
  }) async {
    final source = _source(body);
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    assert(source.startsWith(node, at), 'the marker precedes $node');
    await assertDiagnostics(source, [
      lint(
        at,
        node.length,
        messageContainsAll: [
          "'$read' is read before this await and '$written' written",
        ],
      ),
    ]);
  }

  Future<void> test_a_read_the_call_takes_before_the_await() => _ok('''
Future<void> f(Sites sites, Site site) async {
  log(sites.loaded);
  await pause();
  site.dispose(commit: drop);
}
''');

  Future<void> test_read_again_after_the_await() => _ok('''
Future<void> f(Sites sites) async {
  final s = sites.shown;
  await pause();
  if (sites.shown != s) return;
  s?.dispose(commit: drop);
}
''');

  Future<void> test_await_and_write_on_other_branches() => _ok('''
Future<void> f(Sites sites, Site site) async {
  if (sites.loaded.contains(site)) {
    await pause();
  } else {
    site.dispose(commit: drop);
  }
}
''');

  Future<void> test_both_branches_go_on() => _ok('''
Future<void> f(Sites sites, Site site) async {
  if (identical(sites.shown, site)) {
    await pause();
  }
  site.dispose(commit: drop);
}
''');

  Future<void> test_a_local_not_read_after_the_await() => _ok('''
Future<void> f(Sites sites, Site site) async {
  final s = sites.shown;
  log(s);
  await pause();
  site.dispose(commit: drop);
}
''');

  Future<void> test_the_write_before_the_await() => _ok('''
Future<void> f(Sites sites) async {
  final s = sites.shown;
  s?.dispose(commit: drop);
  await pause();
}
''');

  Future<void> test_a_local_rebound_after_the_await() => _ok('''
Future<void> f(Sites sites, Site site) async {
  var s = sites.shown;
  await pause();
  s = site;
  s.dispose(commit: drop);
}
''');

  Future<void> test_an_await_in_a_closure() => _ok('''
Future<void> f(Sites sites, void Function(Future<void> Function()) later) async {
  final s = sites.shown;
  later(() async {
    await pause();
  });
  s?.dispose(commit: drop);
}
''');

  Future<void> test_a_loop_that_reads_again_each_pass() => _ok('''
Future<void> f(Sites sites) async {
  while (sites.loaded.isNotEmpty) {
    await pause();
    sites.loaded.first.dispose(commit: drop);
  }
}
''');

  Future<void> test_a_held_local() => _caught(
    '''
Future<void> f(Sites sites) async {
  final s = sites.shown;
  /*here*/await pause();
  s?.dispose(commit: drop);
}
''',
    read: 'sites.shown',
    written: 'dispose',
  );

  Future<void> test_a_guard_that_returns() => _caught(
    '''
Future<void> f(Sites sites, Site site) async {
  if (!sites.loaded.contains(site)) return;
  /*here*/await pause();
  site.dispose(commit: drop);
}
''',
    read: 'sites.loaded',
    written: 'dispose',
  );

  Future<void> test_inside_the_branch_it_decides() => _caught(
    '''
Future<void> f(Sites sites, Site site) async {
  if (identical(sites.shown, site)) {
    /*here*/await pause();
    site.dispose(commit: drop);
  }
}
''',
    read: 'sites.shown',
    written: 'dispose',
  );

  Future<void> test_a_decision_from_a_held_local() => _caught(
    '''
Future<void> f(Sites sites, Site site) async {
  final live = sites.loaded.contains(site);
  if (live) {
    /*here*/await pause();
    site.dispose(commit: drop);
  }
}
''',
    read: 'sites.loaded',
    written: 'dispose',
  );

  Future<void> test_an_await_in_the_condition() => _caught(
    '''
Future<void> f(Sites sites, Site site, Future<bool> Function() ask) async {
  if (sites.loaded.contains(site) && /*here*/await ask()) {
    site.dispose(commit: drop);
  }
}
''',
    read: 'sites.loaded',
    written: 'dispose',
    node: 'await ask()',
  );

  Future<void> test_a_loop_over_a_read() => _caught(
    '''
Future<void> f(Sites sites) async {
  for (final s in sites.loaded) {
    /*here*/await pause();
    s.dispose(commit: drop);
  }
}
''',
    read: 'sites.loaded',
    written: 'dispose',
  );

  Future<void> test_the_next_element_after_an_await() => _caught(
    '''
Future<void> f(Sites sites) async {
  for (final s in sites.loaded) {
    s.dispose(commit: drop);
    /*here*/await pause();
  }
}
''',
    read: 'sites.loaded',
    written: 'dispose',
  );

  Future<void> test_a_while_condition_held_across_the_body() => _caught(
    '''
Future<void> f(Sites sites, Site site) async {
  while (sites.loaded.contains(site)) {
    /*here*/await pause();
    site.dispose(commit: drop);
  }
}
''',
    read: 'sites.loaded',
    written: 'dispose',
  );

  Future<void> test_through_another_local() => _caught(
    '''
Future<void> f(Sites sites) async {
  final s = sites.shown;
  /*here*/await pause();
  final t = s;
  t?.dispose(commit: drop);
}
''',
    read: 'sites.shown',
    written: 'dispose',
  );

  Future<void> test_in_a_catch_after_the_await() => _caught(
    '''
Future<void> f(Sites sites) async {
  final s = sites.shown;
  try {
    /*here*/await pause();
  } on Failed {
    s?.dispose(commit: drop);
  }
}
''',
    read: 'sites.shown',
    written: 'dispose',
  );

  Future<void> test_a_shared_cell_captured_by_the_input() => _caught(
    '''
Future<void> f(Sites sites) async {
  final v = sites.version.value;
  /*here*/await pause();
  commitInput(writes: (c) => log(v));
}
''',
    read: 'sites.version.value',
    written: 'commitInput',
  );

  Future<void> test_an_await_for() => _caught(
    '''
Future<void> f(Sites sites, Stream<int> ticks) async {
  final s = sites.shown;
  /*here*/await for (final _ in ticks) {
    s?.dispose(commit: drop);
  }
}
''',
    read: 'sites.shown',
    written: 'dispose',
    node: '''await for (final _ in ticks) {
    s?.dispose(commit: drop);
  }''',
  );

  Future<void> test_outside_lib() async {
    final file = '$testPackageRootPath/test/x_test.dart';
    newFile(
      file,
      _source('''
Future<void> f(Sites sites) async {
  final s = sites.shown;
  await pause();
  s?.dispose(commit: drop);
}
''').replaceAll("import '", "import 'package:test/"),
    );
    await assertNoDiagnosticsInFile(file);
  }
}
