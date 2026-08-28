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

  /// True when [payload] reached the store. False means nothing was written
  /// (no key, no file, an I/O error), and the caller must keep the payload
  /// pending rather than treat it as persisted.
  Future<bool> write(String payload);

  /// Forget everything stored. Must leave nothing behind for the next load
  /// to merge: a reset the user confirmed cannot come back on relaunch.
  Future<void> clear();
}

/// AES-encrypted, on-disk detail blob.
///
/// Models `HtmlCacheService`: a 256-bit AES-GCM key in the platform keychain,
/// the payload sealed under a fresh random nonce per write and written to
/// `<docs>/block_stats/detail.enc`. Unlike the HTML cache the file survives
/// app upgrades — a report wiped by an update is the complaint this answers.
///
/// The nonce has to be per-write rather than key-derived: the detail is
/// rewritten on every flush, so a fixed IV would make successive backups share
/// a byte-identical prefix up to the first block that changed, which is a
/// readout of how much of the user's blocked-host detail moved.
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
      _encrypter = encrypt.Encrypter(
          encrypt.AES(encrypt.Key(Uint8List.fromList(keyBytes)),
              mode: encrypt.AESMode.gcm));
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
      final wireBase64 = await store.readText(_fileName);
      if (wireBase64 == null || wireBase64.isEmpty) return null;
      final wire = base64.decode(wireBase64);
      // 12-byte nonce + 16-byte tag. Anything shorter, a pre-GCM AES-CBC blob,
      // or a tampered one fails below and reads as "no detail" — the report
      // rebuilds from the plaintext counters rather than trusting the bytes.
      if (wire.length < 12 + 16) return null;
      final iv = encrypt.IV(Uint8List.fromList(wire.sublist(0, 12)));
      final body = encrypt.Encrypted(Uint8List.fromList(wire.sublist(12)));
      return encrypter.decrypt(body, iv: iv);
    } catch (e) {
      LogService.instance.log('BlockStats', 'Detail read failed: $e',
          level: LogLevel.warning);
      return null;
    }
  }

  @override
  Future<bool> write(String payload) async {
    await _initialize();
    final store = _store;
    final encrypter = _encrypter;
    if (store == null || encrypter == null) return false;
    try {
      final iv = encrypt.IV.fromSecureRandom(12);
      final enc = encrypter.encrypt(payload, iv: iv);
      final wire = Uint8List(iv.bytes.length + enc.bytes.length)
        ..setRange(0, iv.bytes.length, iv.bytes)
        ..setRange(iv.bytes.length, iv.bytes.length + enc.bytes.length, enc.bytes);
      await store.writeText(_fileName, base64.encode(wire));
      return true;
    } catch (e) {
      LogService.instance.log('BlockStats', 'Detail write failed: $e',
          level: LogLevel.warning);
      return false;
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
