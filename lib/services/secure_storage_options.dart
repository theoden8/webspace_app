import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webspace/demo_data.dart' show isDemoMode;

/// Shared macOS keychain options for every secure-storage service.
///
/// macOS defaults to the data-protection keychain, which requires the app to
/// carry a `keychain-access-groups` entitlement. Demo/test runs are commonly
/// ad-hoc signed — the CI integration-test host has no signing identity, so
/// that entitlement is stripped — and then every keychain read/write fails
/// with `errSecMissingEntitlement` (-34018). In demo mode fall back to the
/// file-based login keychain (no entitlement needed); production keeps the
/// data-protection keychain unchanged.
MacOsOptions demoAwareMacOsOptions() => isDemoMode
    ? const MacOsOptions(usesDataProtectionKeychain: false)
    : const MacOsOptions();
