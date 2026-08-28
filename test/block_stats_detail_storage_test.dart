// The protection report's itemised half on disk (STATS-009): it must come
// back after a restart, and it must not be readable as text when it does.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/block_stats_detail_storage.dart';
import 'package:webspace/services/file_store_io.dart';

import 'helpers/mock_secure_storage.dart' show MockFlutterSecureStorage;

/// A device whose keychain is unusable: Linux without a secret service, an
/// Android Keystore that fails to unlock. The store must degrade, not throw.
class _FailingSecureStorage extends MockFlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      throw Exception('no secret service');
}

void main() {
  late Directory tempDir;
  late MockFlutterSecureStorage keychain;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webspace_block_stats_');
    keychain = MockFlutterSecureStorage();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SecureBlockStatsDetailStore newStore({FlutterSecureStorage? secureStorage}) =>
      SecureBlockStatsDetailStore(
        secureStorage: secureStorage ?? keychain,
        store: IoFileStore('block_stats', overrideRoot: tempDir),
      );

  String payloadFor(String host, String siteId) => jsonEncode({
        'v': 1,
        'cats': {
          'dns': {
            'items': [
              [host, 3, 1700000000000],
            ],
            'sites': [
              [siteId, 3, 1700000000000],
            ],
          },
        },
      });

  Future<List<String>> filesOnDisk() async {
    final dir = Directory('${tempDir.path}/block_stats');
    if (!await dir.exists()) return const [];
    return [for (final e in dir.listSync()) e.path];
  }

  test('a payload written by one launch is read by the next', () async {
    final payload = payloadFor('ads.example', 'site-a');
    await newStore().write(payload);

    expect(await newStore().read(), payload);
  });

  test('the bytes on disk carry neither the host nor the siteId', () async {
    await newStore().write(payloadFor('ads.example', 'site-a'));

    final files = await filesOnDisk();
    expect(files, hasLength(1));
    final bytes = await File(files.single).readAsString();
    expect(bytes, isNot(contains('ads.example')));
    expect(bytes, isNot(contains('site-a')));
  });

  test('clear leaves nothing for the next launch to read', () async {
    final store = newStore();
    await store.write(payloadFor('ads.example', 'site-a'));

    await store.clear();

    expect(await store.read(), isNull);
    expect(await newStore().read(), isNull);
    expect(await filesOnDisk(), isEmpty);
  });

  test('a file the current key cannot open reads as absent, not as a throw',
      () async {
    await newStore().write(payloadFor('ads.example', 'site-a'));

    // A keychain that lost the key mints a new one; the old ciphertext is
    // then undecryptable. The report must survive that as an empty list.
    final rotated = newStore(secureStorage: MockFlutterSecureStorage());

    expect(await rotated.read(), isNull);
  });

  // The store used AES-CBC under an IV that was the first 16 bytes of the key.
  // The detail is rewritten on every flush, so a constant IV made two backups
  // of one device share a byte-identical prefix up to the first block that
  // changed — a readout of how much of the blocked-host detail moved. CBC also
  // left the blob malleable with no MAC.
  test('two writes of the same payload produce unrelated bytes', () async {
    final store = newStore();
    final payload = payloadFor('ads.example', 'site-a');

    await store.write(payload);
    final first = await File((await filesOnDisk()).single).readAsString();
    await store.write(payload);
    final second = await File((await filesOnDisk()).single).readAsString();

    expect(second, isNot(equals(first)));
    expect(second.substring(0, 8), isNot(equals(first.substring(0, 8))),
        reason: 'a fresh nonce per write must change the leading bytes');
    expect(await store.read(), payload);
  });

  test('a tampered blob reads as absent', () async {
    await newStore().write(payloadFor('ads.example', 'site-a'));
    final path = (await filesOnDisk()).single;
    final wire = base64.decode(await File(path).readAsString());
    // Flip a ciphertext byte, past the 12-byte nonce.
    wire[wire.length - 20] ^= 0x01;
    await File(path).writeAsString(base64.encode(wire));

    expect(await newStore().read(), isNull);
  });

  test('no keychain means no detail on disk, and no exception', () async {
    final store = newStore(secureStorage: _FailingSecureStorage());

    await store.write(payloadFor('ads.example', 'site-a'));

    expect(await store.read(), isNull);
    expect(await filesOnDisk(), isEmpty);
  });
}
