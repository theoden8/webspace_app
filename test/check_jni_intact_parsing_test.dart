@Tags(['ci'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Parsing-level guard for `scripts/check_jni_intact.sh`. Stubs
/// `apkanalyzer` with canned `dex packages` output and asserts the script
/// flags a missing/renamed native method -- the signature of R8 shrinking
/// or obfuscation eating the Rust adblock JNI bridge, which otherwise only
/// shows up at runtime as UnsatisfiedLinkError. The expected method set is
/// read by the script from AdblockEngineNative.kt, so this test stays in
/// sync with the real bridge.
void main() {
  late Directory tmp;
  final script = File('scripts/check_jni_intact.sh').absolute.path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('check_jni_intact_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runWithStub(String tree) async {
    final stub = File('${tmp.path}/apkanalyzer');
    stub.writeAsStringSync('#!/usr/bin/env bash\ncat <<\'EOF\'\n$tree\nEOF\n');
    Process.runSync('chmod', ['+x', stub.path]);
    final apk = File('${tmp.path}/app-fdroid-release.apk')..writeAsStringSync('stub');
    return Process.run(
      'bash',
      [script, apk.path],
      // Run from the repo root so the script finds AdblockEngineNative.kt.
      workingDirectory: Directory.current.path,
      environment: {'PATH': '${tmp.path}:${Platform.environment['PATH']}'},
    );
  }

  /// Emits a `dex packages` M row per native method declared in the bridge.
  String treeFor(Iterable<String> nativeMethods) {
    const cls = 'org.codeberg.theoden8.webspace.AdblockEngineNative';
    final rows = <String>['C d 9 9 100 $cls'];
    for (final m in nativeMethods) {
      rows.add('M d 1 1 12 $cls boolean $m(long,java.lang.String)');
    }
    return rows.join('\n');
  }

  List<String> declaredNativeMethods() {
    final kt = File(
      'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/AdblockEngineNative.kt',
    ).readAsStringSync();
    return RegExp(r'external fun ([A-Za-z0-9_]+)')
        .allMatches(kt)
        .map((m) => m.group(1)!)
        .toSet()
        .toList();
  }

  test('all declared native methods present -> passes', () async {
    final methods = declaredNativeMethods();
    expect(methods, isNotEmpty);
    final result = await runWithStub(treeFor(methods));
    expect(result.exitCode, 0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
  });

  test('a missing native method -> fails (UnsatisfiedLinkError guard)',
      () async {
    final methods = declaredNativeMethods()..removeLast();
    final result = await runWithStub(treeFor(methods));
    expect(result.exitCode, 1,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
    expect(result.stderr.toString(), contains('JNI bridge broken'));
  });

  test('a param-type-only mention does not count as the method', () async {
    // The class appears as a *parameter type* of an unrelated method; the
    // native names themselves are absent -> must still fail.
    const cls = 'org.codeberg.theoden8.webspace.AdblockEngineNative';
    final tree = 'C d 1 1 50 com.example.Other\n'
        'M d 1 1 9 com.example.Other void consume($cls)';
    final result = await runWithStub(tree);
    expect(result.exitCode, 1,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
  });
}
