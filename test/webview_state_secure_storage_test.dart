import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';

/// In-memory FlutterSecureStorage for unit tests. The real one binds
/// to platform keychain/keystore and isn't usable from `flutter test`.
class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    AppleOptions? mOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    AppleOptions? mOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
  }) async {
    return _store[key];
  }

  @override
  Future<void> delete({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    AppleOptions? mOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    AppleOptions? mOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    AppleOptions? mOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
  }) async =>
      Map<String, String>.from(_store);

  @override
  Future<void> deleteAll({
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    AppleOptions? mOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store.clear();

  // Unused in tests but required by the interface. Default to no-op.
  @override
  AndroidOptions get aOptions => AndroidOptions.defaultOptions;

  @override
  IOSOptions get iOptions => IOSOptions.defaultOptions;

  @override
  MacOsOptions get mOptions => MacOsOptions.defaultOptions;

  @override
  LinuxOptions get lOptions => LinuxOptions.defaultOptions;

  @override
  WebOptions get webOptions => WebOptions.defaultOptions;

  @override
  WindowsOptions get wOptions => WindowsOptions.defaultOptions;

  @override
  void registerListener({
    required String key,
    required ValueChanged<String?> listener,
  }) {}

  @override
  void unregisterListener({
    required String key,
    required ValueChanged<String?> listener,
  }) {}

  @override
  void unregisterAllListeners() {}

  @override
  void unregisterAllListenersForKey({required String key}) {}

  @override
  Map<String, List<ValueChanged<String?>>> get getListeners => const {};

  @override
  Future<bool?> isCupertinoProtectedDataAvailable() async => true;

  @override
  Stream<bool> get onCupertinoProtectedDataAvailabilityChanged =>
      const Stream.empty();
}

typedef ValueChanged<T> = void Function(T);

void main() {
  late Directory tempDir;
  late _FakeSecureStorage fakeStorage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webspace_state_test_');
    fakeStorage = _FakeSecureStorage();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SecureWebViewStateStorage newStorage({String version = 'v1'}) {
    return SecureWebViewStateStorage(
      secureStorage: fakeStorage,
      overrideAppDir: tempDir,
      versionProvider: () => version,
    );
  }

  group('SecureWebViewStateStorage', () {
    test('save and load round-trip preserves bytes', () async {
      final storage = newStorage();
      final bytes = Uint8List.fromList(List.generate(256, (i) => i));
      await storage.saveState('alpha', bytes);
      final loaded = await storage.loadState('alpha');
      expect(loaded, bytes);
    });

    test('round-trip preserves exact byte content for binary blob', () async {
      final storage = newStorage();
      // Pseudo-random binary, not just incrementing — covers padding /
      // alignment / null-byte edges in the AES-CBC path.
      final raw = List<int>.generate(
        1234,
        (i) => (i * 31 + 7) & 0xFF,
      );
      final bytes = Uint8List.fromList(raw);
      await storage.saveState('binary', bytes);
      final loaded = await storage.loadState('binary');
      expect(loaded, bytes);
    });

    test('load returns null for unknown siteId', () async {
      final storage = newStorage();
      expect(await storage.loadState('does-not-exist'), isNull);
    });

    test('saving empty bytes is a no-op (no file written)', () async {
      final storage = newStorage();
      await storage.saveState('empty', Uint8List(0));
      expect(await storage.loadState('empty'), isNull);
      expect(await storage.siteIds(), isEmpty);
    });

    test('overwrite replaces previous bytes', () async {
      final storage = newStorage();
      await storage.saveState('s', Uint8List.fromList([1, 2, 3]));
      await storage.saveState('s', Uint8List.fromList([10, 20, 30, 40]));
      expect(await storage.loadState('s'), Uint8List.fromList([10, 20, 30, 40]));
    });

    test('removeState deletes the entry from disk', () async {
      final storage = newStorage();
      await storage.saveState('s', Uint8List.fromList([1]));
      expect(await storage.loadState('s'), isNotNull);
      await storage.removeState('s');
      expect(await storage.loadState('s'), isNull);
      expect(await storage.siteIds(), isEmpty);
    });

    test('removeOrphans keeps active siteIds, removes the rest', () async {
      final storage = newStorage();
      await storage.saveState('a', Uint8List.fromList([1]));
      await storage.saveState('b', Uint8List.fromList([2]));
      await storage.saveState('c', Uint8List.fromList([3]));

      final removed = await storage.removeOrphans({'a', 'c'});
      expect(removed, 1);
      expect(await storage.loadState('a'), isNotNull);
      expect(await storage.loadState('b'), isNull);
      expect(await storage.loadState('c'), isNotNull);
    });

    test('siteIds reflects what is currently saved', () async {
      final storage = newStorage();
      await storage.saveState('a', Uint8List.fromList([1]));
      await storage.saveState('b', Uint8List.fromList([2]));
      expect(await storage.siteIds(), {'a', 'b'});
      await storage.removeState('a');
      expect(await storage.siteIds(), {'b'});
    });

    test('persists across instance restarts (same key)', () async {
      // Same encryption key in fakeStorage → same instance can decrypt
      // what a previous instance encrypted, modeling app cold-start
      // with persistent key.
      final s1 = newStorage();
      final bytes = Uint8List.fromList([42, 13, 7, 3, 1]);
      await s1.saveState('persist', bytes);

      final s2 = newStorage();
      final loaded = await s2.loadState('persist');
      expect(loaded, bytes);
    });

    test('app-version upgrade rotates the key and clears state', () async {
      // Save under v1.
      final s1 = newStorage(version: 'v1');
      await s1.saveState('versioned', Uint8List.fromList([99, 88, 77]));
      expect(await s1.loadState('versioned'), isNotNull);

      // Simulate cold start with v2 — the cache dir + key are nuked,
      // previously-stored state is gone.
      final s2 = newStorage(version: 'v2');
      // Trigger init.
      expect(await s2.loadState('versioned'), isNull);
      expect(await s2.siteIds(), isEmpty);
    });

    test('corrupt entry on disk is reaped and load returns null', () async {
      final storage = newStorage();
      await storage.saveState('s', Uint8List.fromList([1, 2, 3]));
      // Corrupt the file by overwriting with garbage.
      final filePath = '${tempDir.path}/webview_state/s.enc';
      await File(filePath).writeAsString('not valid base64!!!');
      // Loading should fail gracefully and clean up the corrupt file.
      expect(await storage.loadState('s'), isNull);
      expect(await File(filePath).exists(), isFalse);
    });

    test('removeState on missing siteId is a no-op (does not throw)',
        () async {
      final storage = newStorage();
      // Reach this without exception.
      await storage.removeState('does-not-exist');
      expect(await storage.loadState('does-not-exist'), isNull);
    });

    test('removeOrphans with empty active set clears everything', () async {
      final storage = newStorage();
      await storage.saveState('a', Uint8List.fromList([1]));
      await storage.saveState('b', Uint8List.fromList([2]));
      final removed = await storage.removeOrphans(const {});
      expect(removed, 2);
      expect(await storage.siteIds(), isEmpty);
    });

    test('different siteIds produce independent entries', () async {
      // Sanity: encrypted-with-fixed-IV doesn't accidentally collide
      // distinct ciphertexts under different filenames.
      final storage = newStorage();
      await storage.saveState('a', Uint8List.fromList([1, 2, 3]));
      await storage.saveState('b', Uint8List.fromList([1, 2, 3])); // same bytes
      expect(await storage.loadState('a'), Uint8List.fromList([1, 2, 3]));
      expect(await storage.loadState('b'), Uint8List.fromList([1, 2, 3]));
      await storage.removeState('a');
      expect(await storage.loadState('a'), isNull);
      expect(await storage.loadState('b'), Uint8List.fromList([1, 2, 3]));
    });
  });
}
