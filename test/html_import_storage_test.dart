import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/file_store_io.dart';
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
      store: IoFileStore('html_imports', overrideRoot: tempDir),
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
    test('corrupt entry stays on disk (not reaped) and returns null in memory',
        () async {
      // Imports are user data, the only copy on the device — never delete
      // on parse failure. The fallback page covers the unreadable case;
      // the encrypted bytes stay in case the AES key recovers later
      // (e.g. transient Android Keystore read failure on next launch).
      final s = await newStorage();
      await s.saveHtml('s', '<p>orig</p>', 'file:///s.html');
      final filePath = '${tempDir.path}/html_imports/s.enc';
      await File(filePath).writeAsString('not valid base64!!!');

      final s2 = await newStorage();
      await s2.preloadAll();

      expect(s2.getHtmlSync('s'), isNull);
      expect(await File(filePath).exists(), isTrue);
    });

    test('lost AES key does not destroy imports on preload', () async {
      // Regression: a flutter_secure_storage read miss (Android Keystore
      // reset, OEM bug, …) caused HtmlImportStorage to generate a fresh
      // AES key on launch, fail to decrypt every existing import, and
      // delete them — wiping the user's only copy of data they imported
      // by hand. The bytes must survive.
      final first = await newStorage();
      await first.saveHtml('a', '<p>kept</p>', 'file:///a.html');
      final filePath = '${tempDir.path}/html_imports/a.enc';
      expect(await File(filePath).exists(), isTrue);

      // Simulate the secure-storage key going missing between launches.
      fakeStorage = MockFlutterSecureStorage();
      final second = await newStorage();
      await second.preloadAll();

      // In-memory load is empty (decrypt failed under the new key),
      // but the encrypted file MUST remain on disk.
      expect(second.getHtmlSync('a'), isNull);
      expect(await File(filePath).exists(), isTrue);
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
      // The siteId-keyed filename is what disambiguates; under GCM the two
      // ciphertexts also differ (see the at-rest group below).
      final s = await newStorage();
      await s.saveHtml('a', '<same>', 'file:///x.html');
      await s.saveHtml('b', '<same>', 'file:///x.html');

      await s.deleteImport('a');
      expect(await s.hasImport('a'), isFalse);
      expect(await s.hasImport('b'), isTrue);
      expect(s.getHtmlSync('b'), '<same>');
    });
  });

  // At-rest shape. The store used AES-CBC under an IV that was the first 16
  // bytes of the key: constant for the key's lifetime, so identical imports
  // produced identical files and a rewrite shared a byte-identical prefix with
  // its predecessor up to the first changed block. CBC also has no integrity,
  // and an import goes straight into the webview as InAppWebViewInitialData.
  group('HtmlImportStorage encryption at rest', () {
    const keyEntry = 'html_import_encryption_key';

    Future<String> fileContents(String siteId) =>
        File('${tempDir.path}/html_imports/$siteId.enc').readAsString();

    /// A blob in the pre-GCM format: AES-CBC under IV = key[0..16].
    Future<void> writeLegacyBlob(String siteId, String plaintext) async {
      final keyBytes = base64.decode(fakeStorage.storage[keyEntry]!);
      final encrypter = encrypt.Encrypter(
        encrypt.AES(encrypt.Key(Uint8List.fromList(keyBytes)),
            mode: encrypt.AESMode.cbc),
      );
      final iv = encrypt.IV(Uint8List.fromList(keyBytes.sublist(0, 16)));
      await IoFileStore('html_imports', overrideRoot: tempDir)
          .writeText('$siteId.enc', encrypter.encrypt(plaintext, iv: iv).base64);
    }

    test('identical imports do not produce identical ciphertext', () async {
      final s = await newStorage();
      await s.saveHtml('a', '<same>', 'file:///x.html');
      await s.saveHtml('b', '<same>', 'file:///x.html');
      expect(await fileContents('a'), isNot(equals(await fileContents('b'))));
    });

    test('rewriting the same import shares no prefix with the previous bytes',
        () async {
      final s = await newStorage();
      await s.saveHtml('a', '<p>one</p>', 'file:///x.html');
      final first = await fileContents('a');
      await s.saveHtml('a', '<p>one</p>', 'file:///x.html');
      final second = await fileContents('a');
      expect(second, isNot(equals(first)));
      expect(second.substring(0, 8), isNot(equals(first.substring(0, 8))),
          reason: 'a fresh nonce per write must change the leading bytes');
    });

    test('a legacy AES-CBC blob still reads', () async {
      final s = await newStorage();
      await s.saveHtml('a', '<p>seed</p>', 'file:///a.html');
      await writeLegacyBlob('a', 'file:///legacy.html\n<p>legacy</p>');

      final reopened = await newStorage();
      final loaded = await reopened.loadHtml('a');
      expect(loaded, isNotNull);
      expect(loaded!.$1, 'file:///legacy.html');
      expect(loaded.$2, '<p>legacy</p>');
    });

    test('a legacy blob is rewritten under GCM on first read', () async {
      final s = await newStorage();
      await s.saveHtml('a', '<p>seed</p>', 'file:///a.html');
      await writeLegacyBlob('a', 'file:///legacy.html\n<p>legacy</p>');
      final before = await fileContents('a');

      final reopened = await newStorage();
      await reopened.preloadAll();

      final after = await fileContents('a');
      expect(after, isNot(equals(before)),
          reason: 'the CBC blob must not survive the first successful read');
      expect(reopened.getHtmlSync('a'), '<p>legacy</p>');

      // And the rewritten bytes are readable by an instance with no legacy
      // path taken: a plain GCM round-trip.
      final third = await newStorage();
      expect((await third.loadHtml('a'))!.$2, '<p>legacy</p>');
    });

    test('a tampered blob reads as absent, not as attacker-chosen HTML',
        () async {
      final s = await newStorage();
      await s.saveHtml('a', '<p>real</p>', 'file:///a.html');
      final wire = base64.decode(await fileContents('a'));
      // Flip a ciphertext byte, past the 12-byte nonce.
      wire[wire.length - 20] ^= 0x01;
      await IoFileStore('html_imports', overrideRoot: tempDir)
          .writeText('a.enc', base64.encode(wire));

      final reopened = await newStorage();
      expect(await reopened.loadHtml('a'), isNull);
      await reopened.preloadAll();
      expect(reopened.getHtmlSync('a'), isNull);
      // Never deleted: imports are the user's only copy (see the robustness
      // group above).
      expect(await File('${tempDir.path}/html_imports/a.enc').exists(), isTrue);
    });
  });
}
