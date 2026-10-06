import 'dart:convert';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/utils/concurrency.dart';

/// The platform keystore each secret lives in, with the options its entries
/// were first written under.
///
/// The options belong to the entries, not to taste: on iOS the
/// accessibility class is part of the keychain query, so a read under
/// another class does not find an item written under this one. The four sets
/// below disagree for historical reasons; making them agree needs a
/// migration of the stored items, not an edit here.
abstract final class Keystores {
  /// Cookies, proxy passwords and saved sign-ins. `first_unlock` so a
  /// background wake with the device locked can still read them.
  static const FlutterSecureStorage credentials = FlutterSecureStorage(
    // The plugin now ignores this flag and migrates such data on first
    // access; it stays so the options are the ones the entries were
    // written with.
    // ignore: deprecated_member_use
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Tor bridge lines (TOR-016). `first_unlock` because a notification
  /// wake with the device locked starts tor too (TOR-006). No Android
  /// options: the entry postdates the deprecated flag.
  static const FlutterSecureStorage torBridges = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Archive slots. iOS keeps its default `unlocked` class: an archive is
  /// only ever opened by the user, never by a background wake.
  static const FlutterSecureStorage archive = FlutterSecureStorage(
    // ignore: deprecated_member_use
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// The AES keys of the encrypted on-disk caches (`KeychainAead`). iOS
  /// default `unlocked`, so a wake with the screen locked cannot read them
  /// (BUG-026).
  static const FlutterSecureStorage aeadKeys = FlutterSecureStorage();
}

/// Runs a keystore call, reporting a refusal as null after logging it.
///
/// A refusal is a [PlatformException] from the plugin or a
/// [MissingPluginException] where no plugin answers. Only the exception's
/// type is logged: the plugins' messages can echo what was stored.
Future<T?> keystoreCall<T extends Object>(
  String logTag,
  String what,
  Future<T> Function() call,
) async {
  try {
    return await call();
  } on PlatformException catch (e) {
    _logRefusal(logTag, what, e);
  } on MissingPluginException catch (e) {
    _logRefusal(logTag, what, e);
  }
  return null;
}

void _logRefusal(String logTag, String what, Exception e) {
  LogService.instance.log(
    logTag,
    'Keystore refused to $what: ${e.runtimeType}',
    level: LogLevel.error,
  );
}

/// What a [SecureJsonStore] does after a keystore call failed.
enum KeystoreFailurePolicy {
  /// Leave the entry alone for the rest of the run. Right for an entry that
  /// is read, changed and written back: after a failed read, writing the
  /// change would replace everything else the entry held.
  stopUsing,

  /// Try again on the next call, and report the last call's outcome in
  /// [SecureJsonStore.isAvailable]. Right for an entry only ever written
  /// whole.
  retry,
}

/// One keystore entry holding a JSON document, read and written whole.
///
/// [decode] receives the parsed JSON, or null when the entry is absent or
/// unreadable, and returns the value to use; it must not throw, so it
/// checks shapes with `is` rather than casting. A value [isEmpty] reports
/// empty deletes the entry rather than storing an empty document.
final class SecureJsonStore<T> {
  SecureJsonStore({
    required FlutterSecureStorage keystore,
    required this.key,
    required this.logTag,
    required T Function(Object? json) decode,
    required Object? Function(T value) encode,
    required bool Function(T value) isEmpty,
    required KeystoreFailurePolicy onFailure,
    required SerialQueue queue,
  })  : _keystore = keystore,
        _decode = decode,
        _encode = encode,
        _isEmpty = isEmpty,
        _onFailure = onFailure,
        _queue = queue;

  final String key;
  final String logTag;
  final FlutterSecureStorage _keystore;
  final T Function(Object? json) _decode;
  final Object? Function(T value) _encode;
  final bool Function(T value) _isEmpty;
  final KeystoreFailurePolicy _onFailure;
  final SerialQueue _queue;
  bool _available = true;

  /// False once a keystore call failed (under [KeystoreFailurePolicy.retry],
  /// until one succeeds). Callers must not fall back to plaintext.
  bool get isAvailable => _available;

  bool get _skip =>
      !_available && _onFailure == KeystoreFailurePolicy.stopUsing;

  /// Runs [action] exclusively of every other action on this store's queue.
  Future<R> exclusive<R>(Future<R> Function() action) => _queue.run(action);

  /// The stored value; `decode(null)` when there is none or it cannot be
  /// read.
  Future<T> read() async {
    if (_skip) return _decode(null);
    final raw = await keystoreCall(
        logTag, 'read $key', () async => await _keystore.read(key: key) ?? '');
    if (raw == null) {
      _available = false;
      return _decode(null);
    }
    _available = true;
    if (raw.isEmpty) return _decode(null);
    try {
      return _decode(jsonDecode(raw));
    } on FormatException {
      LogService.instance.log(logTag, '$key is not JSON; reading it as empty',
          level: LogLevel.error);
      _available = false;
      return _decode(null);
    }
  }

  /// Store [value], or delete the entry when [value] is empty. False when
  /// nothing was written.
  Future<bool> write(T value) async {
    if (_isEmpty(value)) return delete();
    if (_skip) return false;
    return _settle(await keystoreCall(logTag, 'write $key', () async {
      await _keystore.write(key: key, value: jsonEncode(_encode(value)));
      return true;
    }));
  }

  /// Delete the entry. False when nothing was deleted.
  Future<bool> delete() async {
    if (_skip) return false;
    return _settle(await keystoreCall(logTag, 'delete $key', () async {
      await _keystore.delete(key: key);
      return true;
    }));
  }

  bool _settle(bool? done) => _available = done != null;

  /// Read, apply [change], and write back, as one exclusive step. Nothing
  /// is written when the read failed. False when nothing was written.
  Future<bool> update(T Function(T current) change) => exclusive(() async {
        final current = await read();
        if (!_available) return false;
        return write(change(current));
      });
}

extension SecureJsonMapStore<V> on SecureJsonStore<Map<String, V>> {
  /// Drop every entry whose key is not in [activeKeys] and that [pinned]
  /// does not claim, logging the keys dropped as [what].
  Future<void> removeOrphans(
    Set<String> activeKeys, {
    required String what,
    bool Function(String key)? pinned,
  }) async {
    final removed = <String>[];
    await update((map) {
      for (final key in map.keys.toList()) {
        if (activeKeys.contains(key) || (pinned?.call(key) ?? false)) {
          continue;
        }
        map.remove(key);
        removed.add(key);
      }
      return map;
    });
    if (removed.isEmpty) return;
    LogService.instance.log(
      logTag,
      'Removed orphaned $what for: $removed',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
  }
}
