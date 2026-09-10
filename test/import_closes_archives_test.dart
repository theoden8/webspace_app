import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Importing a backup clears the runtime site list. With an archive open
/// that dropped its materialised rows while the handle stayed registered,
/// and the next close sealed the emptiness over the slot (ARCH-010).
void main() {
  final host = File('lib/main.dart').readAsStringSync();

  String body(String signature) {
    final start = host.indexOf(signature);
    expect(start, greaterThan(-1), reason: 'could not find $signature');
    final end = host.indexOf('\n  Future<void> ', start + signature.length);
    return host.substring(start, end < 0 ? host.length : end);
  }

  test('an import seals every open archive before it clears the list', () {
    final import = body('Future<void> _importSettings() async {');
    final close = import.indexOf('await _closeAllArchives();');
    final clear = import.indexOf('_webViewModels.clear();');
    expect(close, greaterThan(-1), reason: 'the import never closes archives');
    expect(clear, greaterThan(-1));
    expect(close, lessThan(clear));
  });

  test('a close never seals fewer rows than the archive opened with', () {
    final close = body('Future<void> _closeArchive(ArchiveHandle handle) async {');
    final guard = close.indexOf(
        'final intact = ownedSites.length >= slice.siteIds.length;');
    expect(guard, greaterThan(-1));
    final save = close.indexOf('await _archive.save(handle);');
    expect(save, greaterThan(guard));
    expect(close.substring(guard, save), contains('if (intact) {'));
  });
}
