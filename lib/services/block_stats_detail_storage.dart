import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/keychain_aead.dart';
import 'package:webspace/services/keystore.dart';
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

/// The detail sealed by [KeychainAead] in `<docs>/block_stats/detail.enc`.
/// Unlike the HTML cache the file survives app upgrades: a report wiped by
/// an update is the complaint this answers.
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
  KeychainAead? _aead;
  Future<void>? _initInFlight;

  SecureBlockStatsDetailStore({
    FlutterSecureStorage? secureStorage,
    FileStore? store,
  })  : _secureStorage = secureStorage ?? Keystores.aeadKeys,
        _overrideStore = store;

  /// Memoized so a load racing the first flush cannot generate two keys and
  /// leave the encrypter using one that was never stored.
  Future<void> _initialize() => _initInFlight ??= _doInitialize();

  Future<void> _doInitialize() async {
    final aead = await KeychainAead.open(_secureStorage, _encryptionKeyKey,
        logTag: 'BlockStats');
    if (aead == null) return;
    final store = _overrideStore ?? defaultFileStore(_storageDir);
    try {
      await store.ensure();
    } on Exception catch (e) {
      LogService.instance.log(
          'BlockStats', 'Detail storage unavailable, counts only: $e',
          level: LogLevel.warning);
      return;
    }
    _aead = aead;
    _store = store;
  }

  @override
  Future<String?> read() async {
    await _initialize();
    final store = _store;
    final aead = _aead;
    if (store == null || aead == null) return null;
    final String? wire;
    try {
      wire = await store.readText(_fileName);
    } on Exception catch (e) {
      LogService.instance.log('BlockStats', 'Detail read failed: $e',
          level: LogLevel.warning);
      return null;
    }
    // A pre-GCM blob or a tampered one reads as "no detail": the report
    // rebuilds from the plaintext counters rather than trusting the bytes.
    if (wire == null || wire.isEmpty) return null;
    return aead.unseal(wire);
  }

  @override
  Future<bool> write(String payload) async {
    await _initialize();
    final store = _store;
    final aead = _aead;
    if (store == null || aead == null) return false;
    try {
      await store.writeText(_fileName, aead.seal(payload));
      return true;
    } on Exception catch (e) {
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
    } on Exception catch (e) {
      LogService.instance.log('BlockStats', 'Detail clear failed: $e',
          level: LogLevel.warning);
    }
  }
}
