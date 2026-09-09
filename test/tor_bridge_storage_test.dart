// TOR-016 storage: bridge configuration round-trips through the keystore,
// and never through a settings export.
//
// The export guard is the important half. A privately-allocated obfs4 bridge
// is allocated to a person: it names a host reachable from a censored
// network, and holding it links its holder to that bridge. Backups get
// mailed and synced, which is the same reasoning PWD-005 applies to proxy
// passwords.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/tor_bridge_secure_storage.dart';
import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// Shape-invented bridge line: a real one would rotate, and committing a
/// live bridge to a public repo burns it for the people using it.
const _bridge =
    'obfs4 192.0.2.10:9443 A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 '
    'cert=abcdEFGH1234ijklMNOP5678qrstUVWX90yzABcdEFghIJklMNop iat-mode=0';

/// In-memory stand-in for the platform keystore. Records writes so a test
/// can assert what would actually be persisted, not just what round-trips.
class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> store = {};
  bool throwOnRead = false;
  bool throwOnWrite = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnRead) throw Exception('keystore unavailable');
    return store[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnWrite) throw Exception('keystore unavailable');
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TorBridgeLine line(String s) => parseTorBridgeLine(s).line!;

  group('round trip', () {
    test('an enabled configuration survives save and load', () async {
      final fake = _FakeSecureStorage();
      final store = TorBridgeSecureStorage(secureStorage: fake);

      final saved = await store.save(TorBridgeConfig(
        enabled: true,
        transport: TorTransport.obfs4,
        lines: [line(_bridge)],
      ));
      expect(saved, isTrue);

      final loaded = await store.load();
      expect(loaded.enabled, isTrue);
      expect(loaded.transport, TorTransport.obfs4);
      expect(loaded.lines.single.raw, _bridge);
    });

    test('an empty keystore yields bridges off, not an error', () async {
      final store = TorBridgeSecureStorage(secureStorage: _FakeSecureStorage());
      final loaded = await store.load();
      expect(loaded.enabled, isFalse);
      expect(loaded.lines, isEmpty);
    });

    test('a line that no longer parses is dropped, not handed to tor',
        () async {
      // A dropped transport or a truncated write must not take the working
      // lines down with it: tor rejects the whole configuration on one bad
      // Bridge line.
      final fake = _FakeSecureStorage();
      fake.store['tor_bridges'] = jsonEncode({
        'enabled': true,
        'transport': 'obfs4',
        'lines': [_bridge, 'obfs3 192.0.2.9:1 X', 'total garbage'],
      });
      final loaded = await TorBridgeSecureStorage(secureStorage: fake).load();
      expect(loaded.lines.length, 1);
      expect(loaded.lines.single.raw, _bridge);
    });

    test('a keystore that throws reads as bridges off', () async {
      // The alternative is telling tor UseBridges 1 with lines we could not
      // read, which fails bootstrap with nothing actionable.
      final fake = _FakeSecureStorage()..throwOnRead = true;
      final store = TorBridgeSecureStorage(secureStorage: fake);
      final loaded = await store.load();
      expect(loaded.enabled, isFalse);
      expect(store.isAvailable, isFalse,
          reason: 'the caller must be able to tell this apart from "none set"');
    });

    test('a failed write reports false rather than claiming success',
        () async {
      // Reporting saved would tell the user they are reaching Tor through a
      // bridge that is not configured.
      final fake = _FakeSecureStorage()..throwOnWrite = true;
      final store = TorBridgeSecureStorage(secureStorage: fake);
      final ok = await store.save(
          TorBridgeConfig(enabled: true, lines: [line(_bridge)]));
      expect(ok, isFalse);
      expect(store.isAvailable, isFalse);
    });
  });

  group('never exported (TOR-016)', () {
    test('bridge lines cannot reach a settings backup', () {
      // Excluded by construction: nothing writes bridge state to
      // SharedPreferences or kExportedAppPrefs, so there is no export path
      // to suppress. This asserts that rather than trusting it — and fails
      // loudly if someone later routes bridges through app prefs.
      final backup = SettingsBackupService.createBackup(
        webViewModels: [WebViewModel(initUrl: 'https://a.com')],
        webspaces: [Webspace.all()],
        themeMode: 0,
        globalPrefs: <String, Object?>{},
      );
      final exported = SettingsBackupService.exportToJson(backup);

      expect(exported.contains('192.0.2.10:9443'), isFalse,
          reason: 'a bridge address leaked into exported JSON');
      expect(exported.contains('cert=abcdEFGH'), isFalse,
          reason: 'a bridge certificate leaked into exported JSON');
      expect(exported.contains('tor_bridges'), isFalse,
          reason: 'the bridge keystore entry leaked into exported JSON');
    });

    test('the export registry has no bridge key', () {
      // The structural half: if a future change registers bridges as an
      // exported app pref, this fails before any data can leak.
      for (final key in kExportedAppPrefs.keys) {
        expect(key.toLowerCase().contains('bridge'), isFalse,
            reason: 'bridge state must not be an exported app pref: $key');
      }
    });
  });
}
