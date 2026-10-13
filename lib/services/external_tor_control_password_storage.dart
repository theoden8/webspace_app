// The password for an external tor's control port (TOR-026), in the
// keystore and never in a backup: it is not an AppPref, so no export path
// reaches it. Global, one per device, so no per-site orphan sweep.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/utils/concurrency.dart';

class ExternalTorControlPasswordStorage {
  ExternalTorControlPasswordStorage({FlutterSecureStorage? secureStorage})
      : _store = SecureJsonStore(
          keystore: secureStorage ?? Keystores.credentials,
          key: 'external_tor_control_password',
          logTag: LogTag.tor,
          decode: (json) => json is String ? json : '',
          encode: (password) => password,
          isEmpty: (password) => password.isEmpty,
          onFailure: KeystoreFailurePolicy.retry,
          queue: SerialQueue(),
        );

  final SecureJsonStore<String> _store;

  /// The saved password, or null when there is none or the keystore
  /// refused.
  Future<String?> load() async {
    final password = await _store.read();
    return password.isEmpty ? null : password;
  }

  /// Saves [password], or forgets it when empty. False when nothing landed.
  Future<bool> save(String password) =>
      _store.exclusive(() => _store.write(password));
}
