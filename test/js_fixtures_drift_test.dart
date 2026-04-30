// Drift check for the JS shim fixtures consumed by Node-side tests
// (test/js/*.test.js). Re-runs the same builders as
// tool/dump_shim_js.dart and fails if any committed fixture differs from
// what the builders produce today.
//
// If this test fails, the fix is always:
//
//     fvm dart run tool/dump_shim_js.dart
//
// then re-commit the fixtures.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../tool/dump_shim_js.dart' as dumper;

void main() {
  group('JS shim fixtures drift check', () {
    final fixtures = dumper.buildAllFixtures();
    // Resolve relative to the test's working directory (the repo root when
    // `flutter test` is invoked normally).
    final root = Directory('test/js_fixtures');

    test('fixtures directory exists', () {
      expect(root.existsSync(), isTrue,
          reason:
              'test/js_fixtures missing — run `fvm dart run tool/dump_shim_js.dart`');
    });

    for (final entry in fixtures.entries) {
      test('${entry.key} matches builder output', () {
        final file = File('${root.path}/${entry.key}');
        expect(file.existsSync(), isTrue,
            reason:
                '${entry.key} missing — run `fvm dart run tool/dump_shim_js.dart`');
        final onDisk = file.readAsStringSync();
        expect(onDisk, equals(entry.value),
            reason:
                '${entry.key} drifted — run `fvm dart run tool/dump_shim_js.dart` to refresh');
      });
    }
  });
}
