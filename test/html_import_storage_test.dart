import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/html_import_storage.dart';

import 'helpers/mock_secure_storage.dart' show MockFlutterSecureStorage;

/// Tests for [HtmlImportStorage] — the persistent store for user-imported
/// HTML files. Exercises round-trip, persistence across instance restarts
/// (i.e. across simulated app upgrades), orphan cleanup, and graceful
/// handling of corrupt entries.
///
/// The defining property vs [HtmlCacheService]: imports survive an app
/// upgrade. The cache wipes on version bump; this store does not.

void main() {
  late Directory tempDir;
  late MockFlutterSecureStorage fakeStorage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webspace_import_test_');
    fakeStorage = MockFlutterSecureStorage();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<HtmlImportStorage> newStorage() async {
    final storage = HtmlImportStorage(
      secureStorage: fakeStorage,
      overrideAppDir: tempDir,
    );
    await storage.initialize();
    return storage;
  }

  group('HtmlImportStorage save/load round-trip', () {
    test('saveHtml + loadHtml preserves content and url', () async {
      final s = await newStorage();
      const html = '<html><body>hello</body></html>';
      const url = 'file:///hello.html';
      await s.saveHtml('site-1', html, url);

      final loaded = await s.loadHtml('site-1');
      expect(loaded, isNotNull);
      expect(loaded!.$1, url);
      expect(loaded.$2, html);
    });

    test('getHtmlSync returns the bytes after saveHtml', () async {
      final s = await newStorage();
      await s.saveHtml('site-1', '<p>hi</p>', 'file:///x.html');
      expect(s.getHtmlSync('site-1'), '<p>hi</p>');
    });

    test('getHtmlSync returns null for unknown siteId', () async {
      final s = await newStorage();
      expect(s.getHtmlSync('does-not-exist'), isNull);
    });

    test('loadHtml returns null for unknown siteId', () async {
      final s = await newStorage();
      expect(await s.loadHtml('does-not-exist'), isNull);
    });

    test('overwrite replaces the previous bytes', () async {
      final s = await newStorage();
      await s.saveHtml('site-1', '<old>', 'file:///page.html');
      await s.saveHtml('site-1', '<new>', 'file:///page.html');

      final loaded = await s.loadHtml('site-1');
      expect(loaded!.$2, '<new>');
      expect(s.getHtmlSync('site-1'), '<new>');
    });

    test('hasImport reflects on-disk presence', () async {
      final s = await newStorage();
      expect(await s.hasImport('site-1'), isFalse);
      await s.saveHtml('site-1', '<p>hi</p>', 'file:///x.html');
      expect(await s.hasImport('site-1'), isTrue);
      await s.deleteImport('site-1');
      expect(await s.hasImport('site-1'), isFalse);
    });
  });

  group('HtmlImportStorage persistence', () {
    test('imports survive a simulated app upgrade (new instance)', () async {
      // Save under one instance, simulate cold start by spinning a fresh
      // instance with the SAME tempDir + SAME secure storage. This is the
      // defining property: unlike HtmlCacheService, no version-based
      // wipe happens.
      final first = await newStorage();
      await first.saveHtml('persist', '<p>kept</p>', 'file:///kept.html');

      final second = await newStorage();
      await second.preloadAll();

      expect(second.getHtmlSync('persist'), '<p>kept</p>');
      final loaded = await second.loadHtml('persist');
      expect(loaded!.$1, 'file:///kept.html');
      expect(loaded.$2, '<p>kept</p>');
    });

    test('preloadAll populates memory store from disk', () async {
      final first = await newStorage();
      await first.saveHtml('a', '<a>', 'file:///a.html');
      await first.saveHtml('b', '<b>', 'file:///b.html');

      final second = await newStorage();
      // Before preload, memory store is empty for sites it never saw.
      expect(second.getHtmlSync('a'), isNull);
      expect(second.getHtmlSync('b'), isNull);

      await second.preloadAll();
      expect(second.getHtmlSync('a'), '<a>');
      expect(second.getHtmlSync('b'), '<b>');
    });
  });

  group('HtmlImportStorage delete + orphans', () {
    test('deleteImport removes file and clears memory store', () async {
      final s = await newStorage();
      await s.saveHtml('site-1', '<p>hi</p>', 'file:///x.html');
      expect(s.getHtmlSync('site-1'), isNotNull);

      await s.deleteImport('site-1');
      expect(s.getHtmlSync('site-1'), isNull);
      expect(await s.loadHtml('site-1'), isNull);
      expect(await s.hasImport('site-1'), isFalse);
    });

    test('deleteImport on missing siteId is a no-op (does not throw)',
        () async {
      final s = await newStorage();
      await s.deleteImport('never-existed');
      expect(s.getHtmlSync('never-existed'), isNull);
    });

    test('removeOrphanedImports keeps active siteIds, removes the rest',
        () async {
      final s = await newStorage();
      await s.saveHtml('a', '<a>', 'file:///a.html');
      await s.saveHtml('b', '<b>', 'file:///b.html');
      await s.saveHtml('c', '<c>', 'file:///c.html');

      await s.removeOrphanedImports({'a', 'c'});

      expect(await s.hasImport('a'), isTrue);
      expect(await s.hasImport('b'), isFalse);
      expect(await s.hasImport('c'), isTrue);
      expect(s.getHtmlSync('b'), isNull);
    });

    test('removeOrphanedImports with empty active set clears everything',
        () async {
      final s = await newStorage();
      await s.saveHtml('a', '<a>', 'file:///a.html');
      await s.saveHtml('b', '<b>', 'file:///b.html');

      await s.removeOrphanedImports(const {});

      expect(await s.hasImport('a'), isFalse);
      expect(await s.hasImport('b'), isFalse);
    });
  });

  group('HtmlImportStorage robustness', () {
    test('corrupt entry on disk is reaped on preload, returns null on load',
        () async {
      final s = await newStorage();
      await s.saveHtml('s', '<p>orig</p>', 'file:///s.html');
      // Corrupt the on-disk file with garbage.
      final filePath = '${tempDir.path}/html_imports/s.enc';
      await File(filePath).writeAsString('not valid base64!!!');

      // Fresh instance to drop in-memory state, then preload.
      final s2 = await newStorage();
      await s2.preloadAll();

      expect(s2.getHtmlSync('s'), isNull);
      expect(await File(filePath).exists(), isFalse);
    });

    test('files larger than 10 MB are not saved', () async {
      final s = await newStorage();
      // 10MB + 1 byte. Built deterministically without allocating a real
      // 10MB string for round-trip.
      final bigHtml = 'a' * (10 * 1024 * 1024 + 1);
      await s.saveHtml('big', bigHtml, 'file:///big.html');
      expect(await s.hasImport('big'), isFalse);
      expect(s.getHtmlSync('big'), isNull);
    });

    test('different siteIds with identical bytes stay independent', () async {
      // Sanity: fixed-IV AES means identical ciphertexts for identical
      // plaintexts. The siteId-keyed filename is what disambiguates.
      final s = await newStorage();
      await s.saveHtml('a', '<same>', 'file:///x.html');
      await s.saveHtml('b', '<same>', 'file:///x.html');

      await s.deleteImport('a');
      expect(await s.hasImport('a'), isFalse);
      expect(await s.hasImport('b'), isTrue);
      expect(s.getHtmlSync('b'), '<same>');
    });
  });
}
