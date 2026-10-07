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
// writes bridge state to SharedPreferences or to an `AppPref`, so
// there is no export path to remember to suppress. The regression test
// asserts that rather than trusting it.
//
// Spec: openspec/specs/tor-proxy/spec.md (TOR-016).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/utils/concurrency.dart';

/// Persists [TorBridgeConfig] in the platform keystore.
class TorBridgeSecureStorage {
  static const String _secureStorageKey = 'tor_bridges';

  /// The queue is per instance, unlike ProxyPasswordSecureStorage's static
  /// one. That one is static because two independent holders (per-site
  /// settings and the global proxy) write the same key and a load-modify-save
  /// from one would clobber the other. Bridges have a single writer, the
  /// settings screen, so an instance queue covers the only real race (rapid
  /// taps on one screen).
  ///
  /// The distinction is not academic: a static queue is chained across every
  /// caller in the process, and a task added inside one `testWidgets`
  /// fake-async zone never completes once that test ends. The next test then
  /// awaits a dead Future forever, and its save silently never lands, which
  /// is exactly how this was found.
  final SecureJsonStore<TorBridgeConfig> _store;

  TorBridgeSecureStorage({FlutterSecureStorage? secureStorage})
      : _store = SecureJsonStore(
          keystore: secureStorage ?? Keystores.torBridges,
          key: _secureStorageKey,
          logTag: 'Tor',
          decode: (json) => json is Map
              ? TorBridgeConfig.fromJson(json.cast<String, Object?>())
              : const TorBridgeConfig(),
          encode: (config) => config.toJson(),
          isEmpty: (_) => false,
          // Only ever written whole, so a keystore that was locked at a
          // background wake is simply asked again next time.
          onFailure: KeystoreFailurePolicy.retry,
          queue: SerialQueue(),
        );

  /// Whether the platform keystore answered the last call. False after a
  /// read or write failed, on which the caller must not fall back to
  /// plaintext.
  bool get isAvailable => _store.isAvailable;

  /// The stored configuration, or the default (bridges off) when there is
  /// none or the keystore refused: bridges off is the safe reading, since
  /// the alternative is telling tor `UseBridges 1` with lines we could not
  /// actually read.
  Future<TorBridgeConfig> load() => _store.read();

  /// [load], or null when the keystore refused, for a caller that can ask
  /// again later rather than keep bridges off.
  Future<TorBridgeConfig?> loadIfReadable() async {
    final config = await _store.read();
    return _store.isAvailable ? config : null;
  }

  /// Replace the stored configuration, returning whether it landed. A false
  /// return must not be reported to the user as saved: they would believe
  /// they are reaching Tor through a bridge that is not configured.
  Future<bool> save(TorBridgeConfig config) =>
      _store.exclusive(() => _store.write(config));

  /// Forget everything. Used when the user clears bridges, and by the
  /// app-data wipe path. A refusal leaves no bridges in force either way.
  Future<void> clear() => _store.exclusive(_store.delete);
}
