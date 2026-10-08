import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/app_prefs.dart';

/// Whether Tor sites can be pointed at a tor already running on the device
/// (TOR-025): Orbot on Android, the tor service on Linux, and on macOS in
/// place of the built-in runtime. Not iOS, where no other app exposes a
/// SOCKS port this one can dial.
bool get externalTorRunsHere =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Where the external tor's SOCKS port listens, as `host:port` (TOR-025),
/// for the runtime's synchronous read.
class ExternalTorSettings {
  ExternalTorSettings._();

  static String get address => AppPref.externalTorAddress.value;

  static Future<void> initialize() async {
    AppPref.externalTorAddress.load(await SharedPreferences.getInstance());
  }

  static Future<void> setAddress(String value) =>
      AppPref.externalTorAddress.set(value);
}
