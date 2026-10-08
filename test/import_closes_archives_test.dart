import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Importing a backup replaces the runtime site list. With an archive open
/// that dropped its materialised rows while the handle stayed registered,
/// and the next close sealed the emptiness over the slot (ARCH-010); the
/// commit seals them first (test/js/site_set_commit.test.js).
void main() {
  final host = File('lib/screens/webspace_page.dart').readAsStringSync();

  String body(String signature) {
    final start = host.indexOf(signature);
    expect(start, greaterThan(-1), reason: 'could not find $signature');
    final end = host.indexOf('\n  Future<void> ', start + signature.length);
    return host.substring(start, end < 0 ? host.length : end);
  }

  test('an import decides everything before it clears the list', () {
    // BACKUP-013: a file value that fails to parse must reject the import
    // while live state is intact, so after the clear only the plan is read.
    final import = body('Future<void> _importSettings() async {');
    final plan = import.indexOf('planSettingsImport(');
    final clear = import.indexOf('await _commitSites(SitesReplaced(');
    expect(plan, greaterThan(-1), reason: 'the import no longer plans');
    expect(plan, lessThan(clear));
    final applied = import.substring(clear);
    expect(applied, isNot(contains('fromJson(')));
    expect(applied, isNot(contains('backup.')));
  });

  test('a close never seals fewer rows than the archive opened with', () {
    final archives =
        File('lib/controllers/archive_controller.dart').readAsStringSync();
    final start = archives.indexOf('  Future<void> close(ArchiveHandle handle) async {');
    expect(start, greaterThan(-1));
    final close = archives.substring(start, archives.indexOf('\n  }\n', start));
    final guard = close.indexOf(
        'final intact = ownedSites.length >= slice.siteIds.length;');
    expect(guard, greaterThan(-1));
    final save = close.indexOf('await _archive.save(handle);');
    expect(save, greaterThan(guard));
    expect(close.substring(guard, save), contains('if (intact) {'));
  });
}
