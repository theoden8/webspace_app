// Writes every model the code declares under FORMAL_OUT, for formal/ to
// check (formal/verify.sh runs it). The engines import Flutter, so it runs
// headless under the test runner, `flutter test test/formal_model/main.dart`,
// which exits 79 because a main declares no tests.
import 'dart:io';

import 'models.dart';

void main() {
  final out = Platform.environment['FORMAL_OUT'];
  if (out == null || out.isEmpty) {
    stderr.writeln('FORMAL_OUT names no directory to write the models to');
    exitCode = 2;
    return;
  }
  final printed = printedModels(handWritten: [
    for (final m in handWrittenModules) File(m).readAsStringSync(),
  ]);
  for (final f in printed) {
    File('$out/${f.path}')
      ..createSync(recursive: true)
      ..writeAsStringSync(f.text);
  }
  stdout.writeln('Wrote ${printed.length} files under $out');
}
