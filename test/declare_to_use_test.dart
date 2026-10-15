// A table's step code reaches the engine's world only through the leaves,
// constants and ports its table declares: every closure a table holds is
// handed a StepView, which has no world (step_table.dart), so an undeclared
// read or write of the model's state does not compile. A site's own
// variables of the model are written only with a Commit, which only the
// runner, a hand-marked input or a named Unmodeled debt gives. Both are rung
// 1; this test is the planted mistake that proves each, resolving a probe
// the compiler must reject beside a control it must accept. The probe lives
// only in the analyzer's overlay, never on disk, so `flutter analyze` never
// sees it. The last test is rung 5, since an enum value no code names still
// compiles: every Unmodeled debt names a write the code still makes.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/step_table.dart';

String _sdk() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) return '$root/bin/cache/dart-sdk';
  final at = Platform.resolvedExecutable.indexOf('/bin/cache/');
  return '${Platform.resolvedExecutable.substring(0, at)}/bin/cache/dart-sdk';
}

Future<List<String>> _errorsIn(String source) async {
  final path = '${Directory.current.path}/test/_declare_to_use_probe.dart';
  final files = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE)
    ..setOverlay(path, content: source, modificationStamp: 0);
  final contexts = AnalysisContextCollection(
    includedPaths: [path],
    resourceProvider: files,
    sdkPath: _sdk(),
  );
  final unit = await contexts.contextFor(path).currentSession.getResolvedUnit(path);
  expect(unit, isA<ResolvedUnitResult>());
  return [
    for (final d in (unit as ResolvedUnitResult).diagnostics)
      if (d.severity == Severity.error) d.diagnosticCode.lowerCaseName,
  ];
}

const _site = '''
import 'dart:typed_data';

import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';
''';

const _world = '''
import 'package:webspace/services/step_table.dart';

final class W {
  int loaded = 0;
}
''';

void main() {
  test('step code that reaches the world does not compile', () async {
    final errors = await _errorsIn('''
$_world
final reach = Expr.op<int, W>('loaded', run: (c) => c.world.loaded, reads: Reads.none);
''');
    expect(errors, ['undefined_getter'],
        reason: "a closure a table holds must not see the engine's world");
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("a call's code that reaches the world does not compile", () async {
    final errors = await _errorsIn('''
$_world
final port = Port<W, W>('w', reads: {ModelVar.loaded}, changes: const {}, of: (w) => w);
final call = Call.on(port, run: (c) async => c.world.loaded, writes: const []);
''');
    expect(errors, ['undefined_getter'],
        reason: "a call's code reaches its port's interface, not the world");
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the same read through a declared port compiles', () async {
    final errors = await _errorsIn('''
$_world
final port = Port<W, W>('w', reads: {ModelVar.loaded}, changes: const {}, of: (w) => w);
final reach = Expr.op<int, W>('loaded', run: (c) => port.from(c).loaded, reads: Reads.none);
final call = Call.on(port, run: (c) async => c.api.loaded, writes: const []);
''');
    expect(errors, isEmpty, reason: 'the probe fails only for the world');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("a site's variables written outside a commit do not compile", () async {
    final errors = await _errorsIn('''
$_site
void f(WebViewModel m) {
  m.tabs = m.tabs;
  m.activeTabId = m.activeTabId;
  m.lifecycleState = m.lifecycleState;
  m.tabBinding.queue(Uint8List(0), tab: m.activeTabId);
}
''');
    expect(errors, [
      ...List.filled(3, 'assignment_to_final_no_setter'),
      'missing_required_argument',
    ], reason: 'tabs, active and tier have no setter outside a commit, and '
        'queued is written only with one');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("the runner's commit cannot be made outside it", () async {
    final errors = await _errorsIn('''
$_site
void f(WebViewModel m) =>
    WebViewModel.tabsCell.write(at: m, to: m.tabs, commit: const Commit._());
''');
    expect(errors, ['const_with_undefined_constructor'],
        reason: "only step_table.dart makes a step's commit");
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the same write under a named debt compiles', () async {
    final errors = await _errorsIn('''
$_site
void f(WebViewModel m) {
  WebViewModel.tabsCell.write(
      at: m, to: m.tabs, commit: const Commit.unmodeled(Unmodeled.tabMove));
  m.tabBinding.queue(Uint8List(0),
      tab: m.activeTabId, commit: const Commit.unmodeled(Unmodeled.tabMove));
}
''');
    expect(errors, isEmpty, reason: 'the probe fails only for the commit');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('every unmodeled write names a write the code still makes', () {
    final named = <String>{
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart') &&
            !f.path.endsWith('services/step_table.dart'))
          for (final m in RegExp(r'Unmodeled\.(\w+)').allMatches(f.readAsStringSync()))
            m[1]!,
    };
    expect({for (final u in Unmodeled.values) u.name}.difference(named), isEmpty,
        reason: 'a debt no write names is paid: drop it from Unmodeled');
  });
}
