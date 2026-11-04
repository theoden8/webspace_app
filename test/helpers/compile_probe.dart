import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart SDK the running Flutter test runs on.
String dartSdk() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) return '$root/bin/cache/dart-sdk';
  final at = Platform.resolvedExecutable.indexOf('/bin/cache/');
  return '${Platform.resolvedExecutable.substring(0, at)}/bin/cache/dart-sdk';
}

/// The error codes the analyzer reports for [source] resolved at [at], with
/// [overlays] standing in for files of the package. Both live only in the
/// analyzer's overlay, never on disk, so `flutter analyze` never sees them.
Future<List<String>> errorsIn(
  String source, {
  String at = 'test/_compile_probe.dart',
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
    sdkPath: dartSdk(),
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
