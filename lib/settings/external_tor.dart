import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/pref_read.dart';

/// Where the external tor's SOCKS port listens, as `host:port` (TOR-025).
const String kExternalTorAddressKey = 'externalTorAddress';

/// Orbot's and the system tor service's SocksPort.
const String kExternalTorDefaultAddress = '127.0.0.1:9050';

/// Whether Tor sites can be pointed at a tor already running on the device
/// (TOR-025): Orbot on Android, the tor service on Linux, and on macOS in
/// place of the built-in runtime. Not iOS, where no other app exposes a
/// SOCKS port this one can dial.
bool get externalTorRunsHere =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// The external tor's address, cached for the runtime's synchronous read.
class ExternalTorSettings {
  ExternalTorSettings._();

  static String _address = kExternalTorDefaultAddress;

  static String get address => _address;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _address = readPrefAs<String>(prefs, kExternalTorAddressKey) ??
        kExternalTorDefaultAddress;
  }

  static Future<void> setAddress(String value) async {
    _address = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kExternalTorAddressKey, value);
  }

  @visibleForTesting
  static void debugSetAddress(String value) => _address = value;
}
