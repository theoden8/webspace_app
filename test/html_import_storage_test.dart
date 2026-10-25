import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/file_store_io.dart';
import 'package:webspace/services/html_import_storage.dart';

import 'helpers/mock_secure_storage.dart' show MockFlutterSecureStorage;

/// Tests for [HtmlImportStorage] — the persistent store for user-imported
/// HTML files. Exercises round-trip, persistence across instance restarts
/// (i.e. across simulated app upgrades), orphan cleanup, and graceful
/// handling of corrupt entries.
///
/// The defining property: imports survive an app upgrade.

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
      await s.saveHtml(SiteId('site-1'), html: html, url: url);

      final loaded = await s.loadHtml(SiteId('site-1'));
      expect(loaded, isNotNull);
      expect(loaded!.$1, url);
      expect(loaded.$2, html);
    });

    test('getHtmlSync returns the bytes after saveHtml', () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('site-1'), html: '<p>hi</p>', url: 'file:///x.html');
      expect(s.getHtmlSync(SiteId('site-1')), '<p>hi</p>');
    });

    test('getHtmlSync returns null for unknown siteId', () async {
      final s = await newStorage();
      expect(s.getHtmlSync(SiteId('does-not-exist')), isNull);
    });

    test('loadHtml returns null for unknown siteId', () async {
      final s = await newStorage();
      expect(await s.loadHtml(SiteId('does-not-exist')), isNull);
    });

    test('overwrite replaces the previous bytes', () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('site-1'), html: '<old>', url: 'file:///page.html');
      await s.saveHtml(SiteId('site-1'), html: '<new>', url: 'file:///page.html');

      final loaded = await s.loadHtml(SiteId('site-1'));
      expect(loaded!.$2, '<new>');
      expect(s.getHtmlSync(SiteId('site-1')), '<new>');
    });

    test('hasImport reflects on-disk presence', () async {
      final s = await newStorage();
      expect(await s.hasImport(SiteId('site-1')), isFalse);
      await s.saveHtml(SiteId('site-1'), html: '<p>hi</p>', url: 'file:///x.html');
      expect(await s.hasImport(SiteId('site-1')), isTrue);
      await s.removeOrphanedImports(const {});
      expect(await s.hasImport(SiteId('site-1')), isFalse);
    });
  });

  group('HtmlImportStorage persistence', () {
    test('imports survive a simulated app upgrade (new instance)', () async {
      // Save under one instance, simulate cold start by spinning a fresh
      // instance with the SAME tempDir + SAME secure storage. This is the
      // defining property: no version-based wipe happens.
      final first = await newStorage();
      await first.saveHtml(SiteId('persist'),
          html: '<p>kept</p>', url: 'file:///kept.html');

      final second = await newStorage();
      await second.preloadOne(SiteId('persist'));

      expect(second.getHtmlSync(SiteId('persist')), '<p>kept</p>');
      final loaded = await second.loadHtml(SiteId('persist'));
      expect(loaded!.$1, 'file:///kept.html');
      expect(loaded.$2, '<p>kept</p>');
    });

    test('preloadOne populates memory store from disk', () async {
      final first = await newStorage();
      await first.saveHtml(SiteId('a'), html: '<a>', url: 'file:///a.html');
      await first.saveHtml(SiteId('b'), html: '<b>', url: 'file:///b.html');

      final second = await newStorage();
      // Before preload, memory store is empty for sites it never saw.
      expect(second.getHtmlSync(SiteId('a')), isNull);
      expect(second.getHtmlSync(SiteId('b')), isNull);

      await second.preloadOne(SiteId('a'));
      expect(second.getHtmlSync(SiteId('a')), '<a>');
      expect(second.getHtmlSync(SiteId('b')), isNull);
      await second.preloadOne(SiteId('b'));
      expect(second.getHtmlSync(SiteId('b')), '<b>');
    });
  });

  group('HtmlImportStorage delete + orphans', () {
    test('removeOrphanedImports keeps active siteIds, removes the rest',
        () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<a>', url: 'file:///a.html');
      await s.saveHtml(SiteId('b'), html: '<b>', url: 'file:///b.html');
      await s.saveHtml(SiteId('c'), html: '<c>', url: 'file:///c.html');

      await s.removeOrphanedImports({SiteId('a'), SiteId('c')});

      expect(await s.hasImport(SiteId('a')), isTrue);
      expect(await s.hasImport(SiteId('b')), isFalse);
      expect(await s.hasImport(SiteId('c')), isTrue);
      expect(s.getHtmlSync(SiteId('b')), isNull);
    });

    test('removeOrphanedImports with empty active set clears everything',
        () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<a>', url: 'file:///a.html');
      await s.saveHtml(SiteId('b'), html: '<b>', url: 'file:///b.html');

      await s.removeOrphanedImports(const {});

      expect(await s.hasImport(SiteId('a')), isFalse);
      expect(await s.hasImport(SiteId('b')), isFalse);
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
      await s.saveHtml(SiteId('s'), html: '<p>orig</p>', url: 'file:///s.html');
      final filePath = '${tempDir.path}/html_imports/s.enc';
      await File(filePath).writeAsString('not valid base64!!!');

      final s2 = await newStorage();
      await s2.preloadOne(SiteId('s'));

      expect(s2.getHtmlSync(SiteId('s')), isNull);
      expect(await File(filePath).exists(), isTrue);
    });

    test('lost AES key does not destroy imports on preload', () async {
      // Regression: a flutter_secure_storage read miss (Android Keystore
      // reset, OEM bug, …) caused HtmlImportStorage to generate a fresh
      // AES key on launch, fail to decrypt every existing import, and
      // delete them — wiping the user's only copy of data they imported
      // by hand. The bytes must survive.
      final first = await newStorage();
      await first.saveHtml(SiteId('a'), html: '<p>kept</p>', url: 'file:///a.html');
      final filePath = '${tempDir.path}/html_imports/a.enc';
      expect(await File(filePath).exists(), isTrue);

      // Simulate the secure-storage key going missing between launches.
      fakeStorage = MockFlutterSecureStorage();
      final second = await newStorage();
      await second.preloadOne(SiteId('a'));

      // In-memory load is empty (decrypt failed under the new key),
      // but the encrypted file MUST remain on disk.
      expect(second.getHtmlSync(SiteId('a')), isNull);
      expect(await File(filePath).exists(), isTrue);
    });

    test('files larger than 10 MB are not saved', () async {
      final s = await newStorage();
      // 10MB + 1 byte. Built deterministically without allocating a real
      // 10MB string for round-trip.
      final bigHtml = 'a' * (10 * 1024 * 1024 + 1);
      await s.saveHtml(SiteId('big'), html: bigHtml, url: 'file:///big.html');
      expect(await s.hasImport(SiteId('big')), isFalse);
      expect(s.getHtmlSync(SiteId('big')), isNull);
    });

    test('different siteIds with identical bytes stay independent', () async {
      // The siteId-keyed filename is what disambiguates; under GCM the two
      // ciphertexts also differ (see the at-rest group below).
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<same>', url: 'file:///x.html');
      await s.saveHtml(SiteId('b'), html: '<same>', url: 'file:///x.html');

      await s.removeOrphanedImports({SiteId('b')});
      expect(await s.hasImport(SiteId('a')), isFalse);
      expect(await s.hasImport(SiteId('b')), isTrue);
      expect(s.getHtmlSync(SiteId('b')), '<same>');
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
Future<void> writeLegacyBlob(String siteId, {required String plaintext}) async {
  final keyBytes = base64.decode(fakeStorage.storage[keyEntry]!);
  final encrypter = encrypt.Encrypter(
    encrypt.AES(encrypt.Key(Uint8List.fromList(keyBytes)),
        mode: encrypt.AESMode.cbc),
  );
  final iv = encrypt.IV(Uint8List.fromList(keyBytes.sublist(0, 16)));
  await IoFileStore('html_imports', overrideRoot: tempDir).writeText(
      '$siteId.enc',
      contents: encrypter.encrypt(plaintext, iv: iv).base64);
}

    test('identical imports do not produce identical ciphertext', () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<same>', url: 'file:///x.html');
      await s.saveHtml(SiteId('b'), html: '<same>', url: 'file:///x.html');
      expect(await fileContents('a'), isNot(equals(await fileContents('b'))));
    });

    test('rewriting the same import shares no prefix with the previous bytes',
        () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<p>one</p>', url: 'file:///x.html');
      final first = await fileContents('a');
      await s.saveHtml(SiteId('a'), html: '<p>one</p>', url: 'file:///x.html');
      final second = await fileContents('a');
      expect(second, isNot(equals(first)));
      expect(second.substring(0, 8), isNot(equals(first.substring(0, 8))),
          reason: 'a fresh nonce per write must change the leading bytes');
    });

    test('a legacy AES-CBC blob still reads', () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<p>seed</p>', url: 'file:///a.html');
      await writeLegacyBlob('a',
          plaintext: 'file:///legacy.html\n<p>legacy</p>');

      final reopened = await newStorage();
      final loaded = await reopened.loadHtml(SiteId('a'));
      expect(loaded, isNotNull);
      expect(loaded!.$1, 'file:///legacy.html');
      expect(loaded.$2, '<p>legacy</p>');
    });

    test('a legacy blob is rewritten under GCM on first read', () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<p>seed</p>', url: 'file:///a.html');
      await writeLegacyBlob('a',
          plaintext: 'file:///legacy.html\n<p>legacy</p>');
      final before = await fileContents('a');

      final reopened = await newStorage();
      await reopened.preloadOne(SiteId('a'));

      final after = await fileContents('a');
      expect(after, isNot(equals(before)),
          reason: 'the CBC blob must not survive the first successful read');
      expect(reopened.getHtmlSync(SiteId('a')), '<p>legacy</p>');

      // And the rewritten bytes are readable by an instance with no legacy
      // path taken: a plain GCM round-trip.
      final third = await newStorage();
      expect((await third.loadHtml(SiteId('a')))!.$2, '<p>legacy</p>');
    });

    test('a tampered blob reads as absent, not as attacker-chosen HTML',
        () async {
      final s = await newStorage();
      await s.saveHtml(SiteId('a'), html: '<p>real</p>', url: 'file:///a.html');
      final wire = base64.decode(await fileContents('a'));
      // Flip a ciphertext byte, past the 12-byte nonce.
      wire[wire.length - 20] ^= 0x01;
      await IoFileStore('html_imports', overrideRoot: tempDir)
          .writeText('a.enc', contents: base64.encode(wire));

      final reopened = await newStorage();
      expect(await reopened.loadHtml(SiteId('a')), isNull);
      await reopened.preloadOne(SiteId('a'));
      expect(reopened.getHtmlSync(SiteId('a')), isNull);
      // Never deleted: imports are the user's only copy (see the robustness
      // group above).
      expect(await File('${tempDir.path}/html_imports/a.enc').exists(), isTrue);
    });
  });

  group('retireSnapshotCache', () {
    test('a fresh install, with no snapshot cache, touches nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final cache = MemoryFileStore();
      await cache.writeText('x.enc', contents: 'left alone');
      final storage = HtmlImportStorage(
          secureStorage: fakeStorage,
          store: IoFileStore('html_imports', overrideRoot: tempDir),
          retiredCache: cache);
      await storage.initialize();
      await storage.retireSnapshotCache();
      expect(await cache.list(), ['x.enc'],
          reason: 'no version stamp: no release ever kept snapshots here');
      expect(fakeStorage.storage.containsKey('html_cache_encryption_key'),
          isFalse);
    });

    test('a locked keychain deletes nothing, so the next start tries again',
        () async {
      SharedPreferences.setMockInitialValues({'html_cache_version': '0.3.2+1'});
      final cache = MemoryFileStore();
      await cache.writeText('s1.enc', contents: 'maybe an import');
      final storage = HtmlImportStorage(
          secureStorage: fakeStorage,
          store: IoFileStore('html_imports', overrideRoot: tempDir),
          retiredCache: cache);
      await storage.initialize();
      fakeStorage.throwOnRead = true;
      await storage.retireSnapshotCache();
      expect(await cache.list(), ['s1.enc'],
          reason: 'an import kept there is unreadable without its key');
      expect((await SharedPreferences.getInstance()).containsKey('html_cache_version'),
          isTrue);
    });
  });
}
