// At-rest store for bridge configuration.
//
// Secure storage, not SharedPreferences, and deliberately outside the
// settings-export registry. A bridge line is not a password, but a
// privately-allocated obfs4 bridge is allocated *to a person*: it names a
// host reachable from a censored network, and possessing it links its holder
// to that bridge. Backups get mailed and synced, so the same reasoning that
// keeps proxy passwords out of exports (PWD-005) applies here.
//
// Excluded from export by construction rather than by a filter: nothing
// writes bridge state to SharedPreferences or to `kExportedAppPrefs`, so
// there is no export path to remember to suppress. The regression test
// asserts that rather than trusting it.
//
// Spec: openspec/specs/tor-proxy/spec.md (TOR-016).

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_bridges.dart';

/// Persists [TorBridgeConfig] in the platform keystore.
class TorBridgeSecureStorage {
  static const String _secureStorageKey = 'tor_bridges';

  final FlutterSecureStorage _secureStorage;
  bool _secureStorageAvailable = true;

  /// Serializes mutations of the single entry. Static so it is shared
  /// across instances, matching ProxyPasswordSecureStorage: an
  /// unsynchronized load-modify-save from two holders would silently drop
  /// one of them.
  static Future<void> _writeLock = Future<void>.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _writeLock.then((_) => action());
    _writeLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  TorBridgeSecureStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              // No `aOptions`: ProxyPasswordSecureStorage still passes
              // `encryptedSharedPreferences`, but the plugin now deprecates
              // and ignores it, and Tor is iOS-only anyway, so the Android
              // options would be dead weight carrying a deprecation.
              //
              // `first_unlock` rather than the default: bridges have to be
              // readable when a BGAppRefreshTask wakes a notification site
              // with the device locked (TOR-006), which the
              // `unlocked`-only accessibility would refuse.
              iOptions: IOSOptions(
                  accessibility: KeychainAccessibility.first_unlock),
            );

  /// Whether the platform keystore answered. False after a read or write
  /// threw — on which the caller must not fall back to plaintext.
  bool get isAvailable => _secureStorageAvailable;

  /// Read the stored configuration, or the default (bridges off) when there
  /// is none.
  ///
  /// A keystore that throws yields the default rather than an exception:
  /// bridges off is the safe reading, since the alternative is telling tor
  /// `UseBridges 1` with lines we could not actually read.
  Future<TorBridgeConfig> load() async {
    try {
      final raw = await _secureStorage.read(key: _secureStorageKey);
      _secureStorageAvailable = true;
      if (raw == null || raw.isEmpty) return const TorBridgeConfig();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const TorBridgeConfig();
      return TorBridgeConfig.fromJson(decoded.cast<String, Object?>());
    } catch (e) {
      _secureStorageAvailable = false;
      // No bridge line in the message: this log ends up in the app log and
      // in bug reports.
      LogService.instance.log(
        'Tor',
        'Could not read bridge configuration from secure storage: '
            '${e.runtimeType}',
        level: LogLevel.warning,
      );
      return const TorBridgeConfig();
    }
  }

  /// Replace the stored configuration.
  ///
  /// Returns whether it landed. A false return must not be reported to the
  /// user as saved: they would believe they are reaching Tor through a
  /// bridge that is not configured.
  Future<bool> save(TorBridgeConfig config) => _synchronized(() async {
        try {
          await _secureStorage.write(
            key: _secureStorageKey,
            value: jsonEncode(config.toJson()),
          );
          _secureStorageAvailable = true;
          return true;
        } catch (e) {
          _secureStorageAvailable = false;
          LogService.instance.log(
            'Tor',
            'Could not write bridge configuration to secure storage: '
                '${e.runtimeType}',
            level: LogLevel.error,
          );
          return false;
        }
      });

  /// Forget everything. Used when the user clears bridges, and by the
  /// app-data wipe path.
  Future<void> clear() => _synchronized(() async {
        try {
          await _secureStorage.delete(key: _secureStorageKey);
        } catch (_) {
          // Nothing useful to do: the entry either never existed or the
          // keystore is unavailable, and both leave us with no bridges.
        }
      });
}
