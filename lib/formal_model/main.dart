// Writes every model the code declares under FORMAL_OUT, for formal/ to
// check (formal/verify.sh runs it). A separate entry point, as the design
// app is: the engines import Flutter, so it runs headless under the test
// runner, `flutter test lib/formal_model/main.dart`, which exits 79 because
// a main declares no tests.
import 'dart:io';

import 'package:webspace/formal_model/models.dart';

void main() {
  final out = Platform.environment['FORMAL_OUT'];
  if (out == null || out.isEmpty) {
    stderr.writeln('FORMAL_OUT names no directory to write the models to');
    exitCode = 2;
    return;
  }
  for (final f in printedModels()) {
    File('$out/${f.path}')
      ..createSync(recursive: true)
      ..writeAsStringSync(f.text);
  }
  stdout.writeln('Wrote ${printedModels().length} files under $out');
}
