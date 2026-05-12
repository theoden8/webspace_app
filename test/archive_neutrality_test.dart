import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/web_view_model.dart';

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
}

Uint8List _testKey(int seed) {
  return Uint8List.fromList(
    List<int>.generate(32, (i) => (seed * 17 + i * 31) & 0xff),
  );
}
