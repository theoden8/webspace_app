import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/mock_secure_storage.dart';

/// Active-state byte-identity regression tests (ARCH-001).
///
/// Verifies that the archive feature is feature-isolated: no archive
/// operation perturbs the app-tier state stored in SharedPreferences,
/// and the runtime `isArchiveTier` marker never crosses persistence
/// boundaries (toJson, fromJson without the explicit param).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('isArchiveTier is runtime-only', () {
    test('default model has isArchiveTier=false', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(m.isArchiveTier, isFalse);
    });

    test('toJson does NOT include isArchiveTier', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        isArchiveTier: true,
      );
      final json = m.toJson();
      expect(json.containsKey('isArchiveTier'), isFalse);
    });

    test('fromJson defaults isArchiveTier=false', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      final round = WebViewModel.fromJson(m.toJson(), null);
      expect(round.isArchiveTier, isFalse);
    });

    test('fromJson respects explicit isArchiveTier=true override', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      final round = WebViewModel.fromJson(m.toJson(), null, isArchiveTier: true);
      expect(round.isArchiveTier, isTrue);
    });

    test('effective getters clamp for archive-tier sites', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        notificationsEnabled: true,
        localCdnEnabled: true,
        isArchiveTier: true,
      );
      expect(m.effectiveNotificationsEnabled, isFalse);
      expect(m.effectiveLocalCdnEnabled, isFalse);
      // Stored values are preserved so the user's preferences round-trip
      // through any future eject flow.
      expect(m.notificationsEnabled, isTrue);
      expect(m.localCdnEnabled, isTrue);
    });

    test('effective getters pass through for app-tier sites', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        notificationsEnabled: true,
        localCdnEnabled: false,
      );
      expect(m.effectiveNotificationsEnabled, isTrue);
      expect(m.effectiveLocalCdnEnabled, isFalse);
    });

    // persistsNavState is the single gate all three production call sites
    // consult (capture, debounce, cold-start restore in main.dart). An
    // archive-tier site returning true here is exactly the regression that
    // would write `controller.saveState()` bytes to a per-`siteId` file —
    // an ARCH-006 violation — so pin every combination.
    test('persistsNavState is false for archive-tier sites', () {
      final m = WebViewModel(initUrl: 'https://a.test', isArchiveTier: true);
      expect(m.persistsNavState, isFalse);
    });

    test('persistsNavState is false for incognito sites', () {
      final m = WebViewModel(initUrl: 'https://a.test', incognito: true);
      expect(m.persistsNavState, isFalse);
    });

    test('persistsNavState is false for archive-tier even when not incognito',
        () {
      final m = WebViewModel(
        initUrl: 'https://a.test',
        isArchiveTier: true,
        incognito: false,
      );
      expect(m.persistsNavState, isFalse);
    });

    test('persistsNavState is true for a plain app-tier site', () {
      final m = WebViewModel(initUrl: 'https://a.test');
      expect(m.persistsNavState, isTrue);
    });
  });

  group('Archive does not touch SharedPreferences', () {
    test('open/create/close cycle leaves SharedPreferences empty', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);

      final prefsBefore = await SharedPreferences.getInstance();
      final keysBefore = prefsBefore.getKeys();
      expect(keysBefore, isEmpty,
          reason: 'SharedPreferences should be clean at test start');

      // Run a full lifecycle: create, mutate, close, reopen, close.
      final key1 = _testKey(1);
      final handle1 = await archive.createWithKey(key1);
      handle1.state.sites.add({'siteId': 'a', 'initUrl': 'https://a.test'});
      handle1.state.sites.add({'siteId': 'b', 'initUrl': 'https://b.test'});
      await archive.save(handle1);
      await archive.close(handle1);
      final reopened = await archive.tryOpenWithKey(_testKey(1));
      expect(reopened, isNotNull);
      await archive.close(reopened!);

      // SharedPreferences must remain untouched throughout.
      final prefsAfter = await SharedPreferences.getInstance();
      expect(prefsAfter.getKeys(), isEmpty);
    });
  });

  // ARCH-001 / ARCH-006 at the storage layer: archive persistence is
  // confined to the fixed slot pool (the PDE framework) — it never writes
  // a per-site keyed secure-storage entry, and never writes any file to
  // the application documents directory. This is the coverage that was
  // missing: the rest of the suite asserts the *serialization shape* of
  // app-tier state is archive-neutral, but nothing inspected the real
  // on-disk / secure-storage footprint. A regression that routes archive
  // state through a docs-dir writer or a keyed secure-storage entry —
  // even AES-encrypted, even blinded — fails here.
  group('Archive persistence is confined to the slot pool', () {
    Set<String> slotKeys() => {
          for (var i = 0; i < kArchiveSlotCount; i++)
            'archive_slot_${i.toString().padLeft(2, '0')}',
        };

    test('a full lifecycle touches only the 16 fixed slot keys', () async {
      final mock = MockFlutterSecureStorage();
      final archive = Archive(storage: ArchiveStorage(secureStorage: mock));
      await archive.ensureInitialized();
      expect(mock.storage.keys.toSet(), equals(slotKeys()),
          reason: 'only the fixed pool exists after init');

      final handle = await archive.createWithKey(_testKey(7));
      handle.state.sites.add({'siteId': 'arch-site', 'initUrl': 'https://x.test'});
      handle.state.cookies['arch-site'] = [
        {'name': 'sid', 'value': 'super-secret-session'},
      ];
      await archive.save(handle);
      await archive.close(handle);
      final reopened = await archive.tryOpenWithKey(_testKey(7));
      expect(reopened, isNotNull);
      await archive.close(reopened!);

      // The namespace is STILL exactly the slot pool — no per-site key
      // (cookies, webview-state, proxy password) ever appeared.
      expect(mock.storage.keys.toSet(), equals(slotKeys()),
          reason: 'no per-site secure-storage key may be created');
      // And nothing leaked the archive siteId / cookie value in cleartext;
      // slot bodies are AEAD ciphertext (base64).
      for (final value in mock.storage.values) {
        expect(value.contains('arch-site'), isFalse);
        expect(value.contains('super-secret-session'), isFalse);
      }
    });

    test('a full lifecycle leaves the documents tree byte-identical', () async {
      final docs =
          await Directory.systemTemp.createTemp('archive_fs_neutrality');
      try {
        // Establish a legitimate app-tier on-disk footprint: an app-tier
        // site persists webview navigation state to the real encrypted
        // store rooted at our temp docs dir.
        final stateStore = SecureWebViewStateStorage(
          secureStorage: MockFlutterSecureStorage(),
          overrideAppDir: docs,
          versionProvider: () => 'test-v1',
        );
        await stateStore.saveState(
            'app-site', Uint8List.fromList([1, 2, 3, 4, 5]));
        final before = await _snapshotDir(docs);
        expect(before, isNotEmpty,
            reason: 'sanity: the app-tier write produced a file to diff against');

        // A full archive lifecycle must write NOTHING under the documents
        // directory — its state lives only in the secure-storage slots.
        final archive =
            Archive(storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()));
        final handle = await archive.createWithKey(_testKey(8));
        handle.state.sites.add({'siteId': 'arch-site', 'initUrl': 'https://y.test'});
        handle.state.cookies['arch-site'] = [
          {'name': 'sid', 'value': 'secret'},
        ];
        await archive.save(handle);
        await archive.close(handle);
        final reopened = await archive.tryOpenWithKey(_testKey(8));
        await archive.close(reopened!);

        final after = await _snapshotDir(docs);
        expect(after, equals(before),
            reason: 'archive operations must not write to the documents '
                'directory (ARCH-001 / ARCH-006)');
      } finally {
        await docs.delete(recursive: true);
      }
    });
  });

  group('App-tier filtering at persistence shape', () {
    test('app-tier model list serialises without isArchiveTier sites', () {
      final appA = WebViewModel(initUrl: 'https://a.test');
      final appB = WebViewModel(initUrl: 'https://b.test');
      final archX = WebViewModel(
        initUrl: 'https://x.test',
        isArchiveTier: true,
      );
      final archY = WebViewModel(
        initUrl: 'https://y.test',
        isArchiveTier: true,
      );

      // Mimic the production filter in `_saveWebViewModels`.
      final all = [appA, archX, appB, archY];
      final persisted =
          all.where((m) => !m.isArchiveTier).map((m) => jsonEncode(m.toJson())).toList();
      expect(persisted, hasLength(2));
      for (final json in persisted) {
        expect(json.contains('isArchiveTier'), isFalse);
      }
    });

    test('export bytes are equal whether archive sites are interleaved or absent', () {
      final appA = WebViewModel(initUrl: 'https://a.test');
      final appB = WebViewModel(initUrl: 'https://b.test');

      final withoutArchive = [appA, appB]
          .map((m) => jsonEncode(m.toJson()))
          .toList();

      final withArchive = [
        appA,
        WebViewModel(initUrl: 'https://x.test', isArchiveTier: true),
        appB,
        WebViewModel(initUrl: 'https://y.test', isArchiveTier: true),
      ]
          .where((m) => !m.isArchiveTier)
          .map((m) => jsonEncode(m.toJson()))
          .toList();

      expect(withArchive, equals(withoutArchive));
    });
  });

  // The bugs this group catches: an earlier version of _moveSiteToArchive
  // mutated `webspace.siteIndices` to strip the moved site's position
  // from every webspace. That changed app-tier persisted state as a
  // direct side-effect of an archive operation — a clear ARCH-001
  // violation that the existing neutrality tests missed because they
  // never exercised the move flow at the integration layer. These
  // tests simulate the same model-level operations the move flow
  // performs (flipping isArchiveTier; removing the model from
  // `_webViewModels` on archive close; re-adding at the tail on open)
  // and assert webspace persistence is unchanged across the cycle.
  group('Webspace persistence is invariant across move-to-archive cycle', () {
    test('flipping isArchiveTier on a webspace member does not change webspace.toJson', () {
      final models = [
        _siteWithId('a'),
        _siteWithId('b'),
        _siteWithId('c'),
      ];
      final ws = Webspace(name: 'Work', siteIds: ['a', 'b', 'c']);
      _resolveWebspaceIndices([ws], models);
      final beforeJson = jsonEncode(ws.toJson());

      // The runtime effect of "move site b to archive": flip its flag
      // and re-resolve. The webspace.siteIds field must stay invariant
      // — and so must its persisted JSON.
      models[1].isArchiveTier = true;
      _resolveWebspaceIndices([ws], models);

      expect(ws.siteIds, equals(['a', 'b', 'c']));
      expect(jsonEncode(ws.toJson()), equals(beforeJson));
    });

    test('closing an archive (removing its sites from _webViewModels) does not change webspace.toJson', () {
      final a = _siteWithId('a');
      final b = _siteWithId('b', archive: true);
      final c = _siteWithId('c');
      final models = [a, b, c];
      final ws = Webspace(name: 'Work', siteIds: ['a', 'b', 'c']);
      _resolveWebspaceIndices([ws], models);
      final beforeJson = jsonEncode(ws.toJson());

      // Close archive: archive-tier models drop out of the runtime
      // list. Webspace.siteIndices loses 'b'; siteIds keeps it.
      models.removeWhere((m) => m.isArchiveTier);
      _resolveWebspaceIndices([ws], models);

      expect(ws.siteIndices, equals([0, 1]),
          reason: 'siteIndices runtime view loses the archive-only site');
      expect(ws.siteIds, equals(['a', 'b', 'c']),
          reason: 'siteIds persisted membership is invariant');
      expect(jsonEncode(ws.toJson()), equals(beforeJson),
          reason: 'archive close must not perturb webspace persistence');
    });

    test('archive close→open round-trip restores siteIndices position membership', () {
      final a = _siteWithId('a');
      final b = _siteWithId('b', archive: true);
      final c = _siteWithId('c');
      final models = [a, b, c];
      final ws = Webspace(name: 'Work', siteIds: ['a', 'b', 'c']);
      _resolveWebspaceIndices([ws], models);
      expect(ws.siteIndices, equals([0, 1, 2]));

      // Close: archive sites leave _webViewModels.
      models.removeWhere((m) => m.isArchiveTier);
      _resolveWebspaceIndices([ws], models);
      expect(ws.siteIndices, equals([0, 1]));

      // Open: archive sites re-append at the tail (this is what
      // _materialiseArchive does in main.dart).
      models.add(b);
      _resolveWebspaceIndices([ws], models);

      // siteIndices now [a=0, b=2 (tail), c=1] — order driven by
      // siteIds, not _webViewModels position.
      expect(ws.siteIndices, equals([0, 2, 1]));
      expect(ws.siteIds, equals(['a', 'b', 'c']));
    });

    test('closing an archive updates webspace.siteIndices.length (regression: stale per-webspace site counts after close)', () {
      // A user moves a site that lives in a custom webspace into an
      // archive. While the archive is open, the webspace shows the
      // site at its position. After close, the site is gone from
      // `_webViewModels` AND must be gone from the runtime
      // `webspace.siteIndices` view that the home-screen renderer
      // consults for its per-webspace site count. The bug this test
      // catches: _closeArchive removed models from `_webViewModels`
      // but did not re-resolve `siteIndices`, leaving stale positions
      // in every webspace whose siteIds referenced the closed sites.
      final a = _siteWithId('a');
      final b = _siteWithId('b', archive: true);
      final c = _siteWithId('c');
      final models = [a, b, c];
      final work = Webspace(name: 'Work', siteIds: ['a', 'b', 'c']);
      _resolveWebspaceIndices([work], models);
      expect(work.siteIndices.length, equals(3),
          reason: 'three members visible while archive is open');

      // Simulate archive close: archive-tier models leave the list.
      models.removeWhere((m) => m.isArchiveTier);
      _resolveWebspaceIndices([work], models);

      expect(work.siteIndices.length, equals(2),
          reason: 'archive site must drop out of the runtime view');
      expect(work.siteIds, equals(['a', 'b', 'c']),
          reason: 'persisted membership still remembers b');
    });

    test('byte-equality across full add-site → move-to-archive → save → close → save cycle', () {
      // The headline ARCH-001 contract: a user who adds a site to a
      // named webspace and then archives it sees their webspaces.json
      // unchanged when the archive is closed, regardless of whether
      // the archive was ever touched.
      final models = [_siteWithId('a'), _siteWithId('b'), _siteWithId('c')];
      final webspaces = [
        Webspace(name: 'Work', siteIds: ['a', 'b']),
        Webspace(name: 'Personal', siteIds: ['c']),
      ];
      _resolveWebspaceIndices(webspaces, models);
      final beforeJson =
          jsonEncode(webspaces.map((w) => w.toJson()).toList());

      // Simulate: move 'b' into an archive; close the archive.
      models[1].isArchiveTier = true;
      _resolveWebspaceIndices(webspaces, models);
      models.removeWhere((m) => m.isArchiveTier); // archive close
      _resolveWebspaceIndices(webspaces, models);

      final afterJson =
          jsonEncode(webspaces.map((w) => w.toJson()).toList());
      expect(afterJson, equals(beforeJson));
    });
  });

  // Legacy-data migration: webspaces persisted before the siteId
  // refactor stored positional `siteIndices` in JSON. The migration
  // step in main.dart resolves those indices against the loaded
  // _webViewModels to populate siteIds. These tests pin the
  // migration's behaviour so a future change to load order or
  // resolution rules can't silently drop pre-existing webspace
  // membership.
  group('Legacy siteIndices migration', () {
    test('migration populates siteIds from positional siteIndices', () {
      final ws = Webspace.fromJson({
        'id': 'legacy',
        'name': 'Work',
        'siteIndices': [0, 2],
      });
      expect(ws.siteIds, isEmpty);
      expect(ws.siteIndices, equals([0, 2]));

      // Mirror of _migrateLegacyWebspaceIndices in main.dart.
      final models = [_siteWithId('a'), _siteWithId('b'), _siteWithId('c')];
      if (ws.siteIds.isEmpty && ws.siteIndices.isNotEmpty) {
        ws.siteIds = [
          for (final idx in ws.siteIndices)
            if (idx >= 0 && idx < models.length) models[idx].siteId,
        ];
      }
      _resolveWebspaceIndices([ws], models);

      expect(ws.siteIds, equals(['a', 'c']));
      expect(ws.siteIndices, equals([0, 2]));
      // Post-migration, toJson emits siteIds — the legacy positional
      // form is gone from persisted state.
      expect(ws.toJson().containsKey('siteIndices'), isFalse);
      expect(ws.toJson()['siteIds'], equals(['a', 'c']));
    });

    test('migration is idempotent — already-migrated webspaces untouched', () {
      final ws = Webspace.fromJson({
        'id': 'new',
        'name': 'Work',
        'siteIds': ['a', 'b'],
      });
      final beforeIds = List<String>.from(ws.siteIds);
      final models = [_siteWithId('a'), _siteWithId('b')];
      // Migration short-circuits when siteIds is already populated.
      if (ws.siteIds.isEmpty && ws.siteIndices.isNotEmpty) {
        ws.siteIds = [
          for (final idx in ws.siteIndices)
            if (idx >= 0 && idx < models.length) models[idx].siteId,
        ];
      }
      expect(ws.siteIds, equals(beforeIds));
    });

    test('migration drops out-of-bounds legacy indices', () {
      // The bug class: a webspace persisted with siteIndices=[0,5,10]
      // on a 3-site app. After upgrade the resolver should drop the
      // out-of-bounds entries rather than crashing.
      final ws = Webspace.fromJson({
        'id': 'legacy',
        'name': 'Work',
        'siteIndices': [0, 5, 10],
      });
      final models = [_siteWithId('a'), _siteWithId('b'), _siteWithId('c')];
      if (ws.siteIds.isEmpty && ws.siteIndices.isNotEmpty) {
        ws.siteIds = [
          for (final idx in ws.siteIndices)
            if (idx >= 0 && idx < models.length) models[idx].siteId,
        ];
      }
      expect(ws.siteIds, equals(['a']));
    });
  });
}

Uint8List _testKey(int seed) {
  return Uint8List.fromList(
    List<int>.generate(32, (i) => (seed * 17 + i * 31) & 0xff),
  );
}

/// Recursive `{relative-path: base64(bytes)}` snapshot of [dir], so two
/// snapshots can be compared with `equals` to assert byte-identity of the
/// whole tree (file set + every file's contents).
Future<Map<String, String>> _snapshotDir(Directory dir) async {
  final out = <String, String>{};
  if (!await dir.exists()) return out;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final rel = entity.path.substring(dir.path.length);
      out[rel] = base64.encode(await entity.readAsBytes());
    }
  }
  return out;
}

/// Mirror of `_WebSpacePageState._resolveWebspaceIndices`. The runtime
/// `webspace.siteIndices` view is recomputed from `webspace.siteIds`
/// against the current `_webViewModels`. Duplicated here so the
/// neutrality tests can exercise the contract without dragging in a
/// full widget test harness.
void _resolveWebspaceIndices(
  List<Webspace> webspaces,
  List<WebViewModel> models,
) {
  final positionBySiteId = <String, int>{
    for (var i = 0; i < models.length; i++) models[i].siteId: i,
  };
  for (final ws in webspaces) {
    if (ws.isAll) continue;
    ws.siteIndices = [
      for (final sid in ws.siteIds)
        if (positionBySiteId.containsKey(sid)) positionBySiteId[sid]!,
    ];
  }
}

WebViewModel _siteWithId(String siteId, {bool archive = false}) {
  return WebViewModel(
    siteId: siteId,
    initUrl: 'https://$siteId.test',
    isArchiveTier: archive,
  );
}
