import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backs the `flutter_secure_storage` method channel with an in-memory store
/// when the real platform keychain is unavailable, so tests that need a
/// working keychain still run there.
///
/// The ad-hoc-signed macOS CI host can't use the keychain: the
/// data-protection keychain needs a `keychain-access-groups` entitlement
/// ad-hoc signing can't carry (a team-prefixed one — or even a bare one —
/// SIGKILLs the app at launch), and the legacy keychain can't be selected
/// instead because `MacOsOptions.usesDataProtectionKeychain` is a no-op (the
/// Dart map key mismatches the native `useDataProtectionKeyChain` the darwin
/// plugin reads). Every op then returns `errSecMissingEntitlement` (-34018).
///
/// This is capability-probed, not platform-gated: it writes a throwaway key
/// through the real plugin and only installs the fake if that throws. Where
/// the real keychain works — Linux via pass-secret-service, a properly signed
/// device — it leaves the plugin in place, so those runs keep real
/// end-to-end secure-storage coverage.
Future<void> installInMemoryKeychainIfUnavailable() async {
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const probeKey = '__keychain_capability_probe__';
  var available = true;
  try {
    await channel.invokeMethod<void>('write', {
      'key': probeKey,
      'value': '1',
      'options': <String, String>{},
    });
    await channel.invokeMethod<void>('delete', {
      'key': probeKey,
      'options': <String, String>{},
    });
  } on PlatformException {
    available = false;
  } on MissingPluginException {
    available = false;
  }
  if (available) return;

  final store = <String, String>{};
  messenger.setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?) ?? const <Object?, Object?>{};
    switch (call.method) {
      case 'write':
        store[args['key'] as String] = args['value'] as String;
        return null;
      case 'read':
        return store[args['key'] as String];
      case 'readAll':
        return Map<String, String>.from(store);
      case 'delete':
        store.remove(args['key'] as String);
        return null;
      case 'deleteAll':
        store.clear();
        return null;
      case 'containsKey':
        return store.containsKey(args['key'] as String);
      case 'isProtectedDataAvailable':
        return true;
      default:
        return null;
    }
  });
}
