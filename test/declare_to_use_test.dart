// A table's step code reaches the engine's world only through the leaves,
// constants and ports its table declares: every closure a table holds is
// handed a StepView, which has no world (step_table.dart), so an undeclared
// read or write of the model's state does not compile. A site's own
// variables of the model are written only with a Commit, which only the
// runner, a hand-marked input or a named Unmodeled debt gives. Both are rung
// 1; this test is the planted mistake that proves each, resolving a probe
// the compiler must reject beside a control it must accept. The probe lives
// only in the analyzer's overlay, never on disk, so `flutter analyze` never
// sees it. The last tests are rung 5, since an enum value no code names still
// compiles: every Unmodeled debt names a write the code still makes, every
// Environment action one it still writes in, and every HandPaired value the
// one site that names it.

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

Future<List<String>> _errorsIn(
  String source, {
  String at = 'test/_declare_to_use_probe.dart',
  Map<String, String> overlays = const {},
}) async {
  final path = '${Directory.current.path}/$at';
  final files = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE)
    ..setOverlay(path, content: source, modificationStamp: 0);
  for (final MapEntry(:key, :value) in overlays.entries) {
    files.setOverlay('${Directory.current.path}/$key',
        content: value, modificationStamp: 0);
  }
  final contexts = AnalysisContextCollection(
    includedPaths: [path],
    resourceProvider: files,
    sdkPath: _sdk(),
  );
  try {
    final unit = await contexts.contextFor(path).currentSession.getResolvedUnit(path);
    expect(unit, isA<ResolvedUnitResult>());
    return [
      for (final d in (unit as ResolvedUnitResult).diagnostics)
        if (d.severity == Severity.error) d.diagnosticCode.lowerCaseName,
    ];
  } finally {
    await contexts.dispose();
  }
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

enum P implements Pairing { p }
''';

void main() {
  test('a new model variable without a frame reader does not compile', () async {
    const owner = 'lib/services/model_names.dart';
    const reader = 'test/helpers/walk/activation_world.dart';
    final names = File(owner).readAsStringSync();
    final added = names.replaceFirst('enum ModelVar {', '''enum ModelVar {
  parityProbe('the compiler must require a reader', type: 'TRUE'),''');
    expect(added, isNot(names), reason: 'the planted variable must be inserted');
    final source = File(reader).readAsStringSync();
    expect(await _errorsIn(source, at: reader), isEmpty);
    expect(
      await _errorsIn(source, at: reader, overlays: {owner: added}),
      contains('non_exhaustive_switch_expression'),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('step code that reaches the world does not compile', () async {
    final errors = await _errorsIn('''
$_world
final reach = Expr.op<int, W>(P.p, tla: 'loaded', run: (c) => c.world.loaded, reads: Reads.none);
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

  test('a value of the model built outside the core does not compile', () async {
    final errors = await _errorsIn('''
$_world
final raw = Expr<bool, W>(run: (_) => true, tla: 'FALSE', reads: Reads.none);
''');
    expect(errors, ['new_with_undefined_constructor_default'],
        reason: 'a run beside a text is written only as a named kind');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a hand pairing that names no pairing does not compile', () async {
    final errors = await _errorsIn('''
$_world
final unnamed = Expr.handPaired<bool, W>(tla: 'FALSE', run: (_) => false, reads: Reads.none);
final op = Expr.op<bool, W>(tla: 'FALSE', run: (_) => false, reads: Reads.none);
''');
    expect(errors, List.filled(2, 'not_enough_positional_arguments'),
        reason: 'a run beside a text names its pair, so the code lists them');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the same pair named as hand-paired compiles', () async {
    final errors = await _errorsIn('''
$_world
final named = Expr.handPaired<bool, W>(P.p, tla: 'FALSE', run: (_) => false, reads: Reads.none);
final op = Expr.op<bool, W>(P.p, tla: 'FALSE', run: (_) => false, reads: Reads.none);
''');
    expect(errors, isEmpty, reason: 'the probes fail only for the raw constructor and the missing name');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the same read through a declared port compiles', () async {
    final errors = await _errorsIn('''
$_world
final port = Port<W, W>('w', reads: {ModelVar.loaded}, changes: const {}, of: (w) => w);
final reach = Expr.op<int, W>(P.p, tla: 'loaded', run: (c) => port.from(c).loaded, reads: Reads.none);
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
  m.tabBinding.bind(m.activeTabId);
  m.tabBinding.take(tab: m.activeTabId);
  m.tabBinding.unbind();
  m.disposeWebView();
}
''');
    expect(errors, [
      ...List.filled(3, 'assignment_to_final_no_setter'),
      ...List.filled(5, 'missing_required_argument'),
    ], reason: 'tabs, active and tier have no setter outside a commit, and '
        'queued and built, which the frame and a dispose write, are written '
        'only with one');
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
  m.tabBinding.bind(m.activeTabId,
      commit: const Commit.environment(Environment.frame));
  m.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
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

  test("every environment action the code writes in is one it still makes",
      () {
    final named = <String>{
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart') &&
            !f.path.endsWith('services/step_table.dart'))
          for (final m
              in RegExp(r'Environment\.(\w+)').allMatches(f.readAsStringSync()))
            m[1]!,
    };
    expect(
        {for (final e in Environment.values) e.name}.difference(named), isEmpty,
        reason: 'an environment action no write names is gone: drop it');
  });

  test('every hand pairing in the code is one HandPaired value, each named once',
      () {
    final head = RegExp(r'Expr\.(op|handPaired)\b(<[^(]*>)?\(\s*');
    final named = <String, List<String>>{};
    final unnamed = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart') ||
          f.path.endsWith('services/step_table.dart')) {
        continue;
      }
      final source = f.readAsStringSync();
      for (final m in head.allMatches(source)) {
        final at = '${f.path}:${'\n'.allMatches(source.substring(0, m.start)).length + 1}';
        final pair = RegExp(r'HandPaired\.(\w+),').matchAsPrefix(source, m.end);
        if (pair == null) {
          unnamed.add(at);
        } else {
          (named[pair[1]!] ??= []).add(at);
        }
      }
    }
    expect(unnamed, isEmpty, reason: 'a run beside a text names its HandPaired value');
    expect({for (final MapEntry(:key, :value) in named.entries) if (value.length > 1) key: value},
        isEmpty, reason: 'a value is one pairing: give each site its own');
    expect({for (final h in HandPaired.values) h.name}.difference(named.keys.toSet()),
        isEmpty, reason: 'a pairing no site names is paid: drop it from HandPaired');
  });
}
