import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/log_service.dart';

/// Where the protection report's itemised detail lives between runs
/// (STATS-009).
abstract class BlockStatsDetailStore {
  /// The stored payload, or null when there is none (or it cannot be read).
  Future<String?> read();

  Future<void> write(String payload);

  /// Forget everything stored. Must leave nothing behind for the next load
  /// to merge: a reset the user confirmed cannot come back on relaunch.
  Future<void> clear();
}

/// AES-encrypted, on-disk detail blob.
///
/// Models [HtmlImportStorage]: a 256-bit AES-CBC key in the platform
/// keychain, the payload encrypted under an IV derived from that key and
/// written to `<docs>/block_stats/detail.enc`. Unlike the HTML cache the file
/// survives app upgrades — a report wiped by an update is the complaint this
/// answers.
///
/// Blocked hosts and `siteId`s are browsing-derived, so they never join the
/// counters in plaintext SharedPreferences (STATS-005). Every failure path
/// here degrades to "no detail persisted"; there is deliberately no plaintext
/// fallback.
class SecureBlockStatsDetailStore implements BlockStatsDetailStore {
  static const String _storageDir = 'block_stats';
  static const String _fileName = 'detail.enc';
  static const String _encryptionKeyKey = 'block_stats_detail_encryption_key';

  final FlutterSecureStorage _secureStorage;
  final FileStore? _overrideStore;

  FileStore? _store;
  encrypt.Encrypter? _encrypter;
  encrypt.IV? _iv;
  Future<void>? _initInFlight;

  SecureBlockStatsDetailStore({
    FlutterSecureStorage? secureStorage,
    FileStore? store,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _overrideStore = store;

  /// Memoized so a load racing the first flush cannot generate two keys and
  /// leave the encrypter using one that was never stored.
  Future<void> _initialize() => _initInFlight ??= _doInitialize();

  Future<void> _doInitialize() async {
    try {
      final store = _overrideStore ?? defaultFileStore(_storageDir);
      var keyBase64 = await _secureStorage.read(key: _encryptionKeyKey);
      if (keyBase64 == null) {
        keyBase64 = base64.encode(encrypt.Key.fromSecureRandom(32).bytes);
        await _secureStorage.write(key: _encryptionKeyKey, value: keyBase64);
      }
      final keyBytes = base64.decode(keyBase64);
      _iv = encrypt.IV(Uint8List.fromList(keyBytes.sublist(0, 16)));
      _encrypter = encrypt.Encrypter(
          encrypt.AES(encrypt.Key(Uint8List.fromList(keyBytes)),
              mode: encrypt.AESMode.cbc));
      await store.ensure();
      _store = store;
    } catch (e) {
      _store = null;
      _encrypter = null;
      LogService.instance.log(
          'BlockStats', 'Detail storage unavailable, counts only: $e',
          level: LogLevel.warning);
    }
  }

  @override
  Future<String?> read() async {
    await _initialize();
    final store = _store;
    final encrypter = _encrypter;
    if (store == null || encrypter == null) return null;
    try {
      final ciphertext = await store.readText(_fileName);
      if (ciphertext == null || ciphertext.isEmpty) return null;
      return encrypter.decrypt64(ciphertext, iv: _iv);
    } catch (e) {
      LogService.instance.log('BlockStats', 'Detail read failed: $e',
          level: LogLevel.warning);
      return null;
    }
  }

  @override
  Future<void> write(String payload) async {
    await _initialize();
    final store = _store;
    final encrypter = _encrypter;
    if (store == null || encrypter == null) return;
    try {
      await store.writeText(_fileName, encrypter.encrypt(payload, iv: _iv).base64);
    } catch (e) {
      LogService.instance.log('BlockStats', 'Detail write failed: $e',
          level: LogLevel.warning);
    }
  }

  @override
  Future<void> clear() async {
    await _initialize();
    final store = _store;
    if (store == null) return;
    try {
      await store.delete(_fileName);
    } catch (e) {
      LogService.instance.log('BlockStats', 'Detail clear failed: $e',
          level: LogLevel.warning);
    }
  }
}
