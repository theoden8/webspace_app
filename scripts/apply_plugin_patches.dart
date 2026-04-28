// Applies WebSpace's per-plugin patches to fresh upstream copies of the
// flutter_inappwebview platform packages, writing the patched results
// into .dart_tool/webspace_patched_plugins/<plugin>/. pubspec.yaml's
// dependency_overrides point at those paths.
//
// Why this exists, in short: stock flutter_inappwebview locks each
// WebView to a default data store before Dart's `onWebViewCreated`
// fires, so per-site profile binding can't be done from the app side.
// Each .patch teaches the corresponding plugin to honor a new
// `webspaceProfile` settings field, binding the WebView before any
// session-bound op. See third_party/PATCHES.md for the full rationale.
//
// Usage:
//
//   dart run scripts/apply_plugin_patches.dart
//
// Ordering with pub get:
//
//   1. `flutter pub get` (populates ~/.pub-cache with upstream plugins).
//   2. This script (copies + patches).
//   3. `flutter pub get` again (resolves the dependency_overrides path
//      dependencies to the now-patched copies).
//
// On a clean checkout, that double-pub-get sequence is the contract.
// CI ([.github/workflows/build-and-test.yml]) chains the three steps.
//
// Failure modes:
//
//   - Missing pub-cache entry → script reports the upstream version it
//     wanted and the path it looked for. Run pub get first.
//   - Patch fails to apply → the upstream plugin moved the lines we
//     touch. Bump _plugins to the new version, rebase the patch by
//     hand against the new upstream (see third_party/PATCHES.md), then
//     re-run.

import 'dart:io';

/// Versions are pinned here, NOT in pubspec.yaml. We override the
/// plugin via `path:` so pub doesn't see the upstream version
/// constraint at all — but we still need to know which upstream
/// version each patch was generated against. Bump in lockstep with
/// the patch file.
const _plugins = <String, String>{
  'flutter_inappwebview_android': '1.1.3',
  'flutter_inappwebview_ios': '1.1.2',
  'flutter_inappwebview_macos': '1.1.2',
};

const _outDir = '.dart_tool/webspace_patched_plugins';

Future<void> main(List<String> args) async {
  // Resolve paths relative to the project root. The script may be
  // invoked from anywhere via `dart run`; locate the root by walking
  // up to the directory holding this script's parent (`scripts/..`).
  final scriptFile = File.fromUri(Platform.script);
  final projectRoot = scriptFile.parent.parent.path;

  final pubCacheRoot = _resolvePubCacheRoot();
  print('Project root: $projectRoot');
  print('Pub cache: $pubCacheRoot');

  for (final entry in _plugins.entries) {
    final pluginName = entry.key;
    final version = entry.value;
    final upstreamDir = '$pubCacheRoot/hosted/pub.dev/$pluginName-$version';
    final patchFile = '$projectRoot/third_party/$pluginName.patch';
    final outPath = '$projectRoot/$_outDir/$pluginName';

    if (!Directory(upstreamDir).existsSync()) {
      stderr.writeln(
        '\nERROR: upstream $pluginName-$version not found at:\n'
        '  $upstreamDir\n'
        'Run `flutter pub get` first to populate the cache, then re-run '
        'this script.',
      );
      exit(2);
    }
    if (!File(patchFile).existsSync()) {
      stderr.writeln('\nERROR: patch file missing: $patchFile');
      exit(2);
    }

    print('\n[$pluginName] $version');
    // Replace any prior copy. Stale partial copies from a failed apply
    // would otherwise produce confusing patch behavior.
    final outDir = Directory(outPath);
    if (outDir.existsSync()) {
      outDir.deleteSync(recursive: true);
    }
    outDir.createSync(recursive: true);

    // Copy upstream tree into the output dir.
    final cp = await Process.run('cp', ['-r', '$upstreamDir/.', outPath]);
    if (cp.exitCode != 0) {
      stderr.writeln('cp failed: ${cp.stderr}');
      exit(cp.exitCode);
    }

    // Apply the patch from inside the output dir. -p1 strips the `a/`
    // prefix the patches were generated with.
    final apply = await Process.run(
      'patch',
      ['-p1', '--input', patchFile],
      workingDirectory: outPath,
    );
    if (apply.exitCode != 0) {
      stderr.writeln('patch failed for $pluginName:');
      stderr.writeln(apply.stdout);
      stderr.writeln(apply.stderr);
      exit(apply.exitCode);
    }
    print(apply.stdout.toString().trim());

    // Sanity check: every patched file should contain at least one
    // marker comment so a future grep across the patched tree finds
    // the WebSpace lines.
    final markerCheck = await Process.run(
      'grep',
      ['-rln', 'WebSpace fork patch', outPath],
    );
    if (markerCheck.exitCode != 0) {
      stderr.writeln(
        'WARN: no [WebSpace fork patch] markers found in patched $pluginName — '
        'the patch may have applied to the wrong place.',
      );
    } else {
      final lines = markerCheck.stdout
          .toString()
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .length;
      print('  marker check: $lines file(s) carry [WebSpace fork patch]');
    }
  }

  print('\nDone. Run `flutter pub get` again so dependency_overrides '
      'resolves the patched paths.');
}

/// Resolve the pub-cache root the way the dart tool does:
/// $PUB_CACHE if set, else `~/.pub-cache`.
String _resolvePubCacheRoot() {
  final env = Platform.environment['PUB_CACHE'];
  if (env != null && env.isNotEmpty) return env;
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    stderr.writeln('Cannot resolve pub cache: neither PUB_CACHE nor HOME set.');
    exit(2);
  }
  return '$home/.pub-cache';
}
