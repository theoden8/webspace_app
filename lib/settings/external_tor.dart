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

/// Whether the external tor's control port can be named (TOR-026): a tor
/// service on the same machine. Orbot and InviZible keep theirs to
/// themselves.
bool get externalTorControlRunsHere =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// What a control endpoint looks like here: the tor service's socket on
/// Linux, a ControlPort elsewhere.
String get externalTorControlExample =>
    defaultTargetPlatform == TargetPlatform.linux
        ? '/run/tor/control'
        : '127.0.0.1:9051';

/// The Tor (external) switch and the SOCKS address of the tor it names, as
/// `host:port` (TOR-025), for the runtime's synchronous reads.
class ExternalTorSettings {
  ExternalTorSettings._();

  /// Whether Tor sites ride the external tor rather than the built-in one.
  static bool get chosen => externalTorRunsHere && AppPref.externalTor.value;

  static String get address => AppPref.externalTorAddress.value;

  /// Where that tor's control port listens, or empty for none (TOR-026).
  static String get control =>
      externalTorControlRunsHere ? AppPref.externalTorControl.value : '';

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    AppPref.externalTor.load(prefs);
    AppPref.externalTorAddress.load(prefs);
    AppPref.externalTorControl.load(prefs);
  }

  static Future<void> setAddress(String value) =>
      AppPref.externalTorAddress.set(value);

  static Future<void> setControl(String value) =>
      AppPref.externalTorControl.set(value);
}
