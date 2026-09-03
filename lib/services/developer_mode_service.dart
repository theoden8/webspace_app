import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';

/// SharedPreferences key holding the developer-mode flag. Round-tripped
/// through settings export/import via `kExportedAppPrefs`.
const String kDeveloperModeKey = 'developerMode';

/// App-global gate for affordances that only make sense while diagnosing the
/// app, not while using it.
///
/// Kept as a service rather than plumbed through widget constructors because
/// it is read from both webview-hosting screens and is not a per-site
/// setting: routing it through the per-site `launchUrl` pipeline would make
/// it look like one. Menus read [enabled] in their `itemBuilder`, which runs
/// each time the menu opens, so a flip needs no rebuild.
class DeveloperModeService {
  DeveloperModeService._();
  static final DeveloperModeService instance = DeveloperModeService._();

  bool _enabled = false;

  /// Whether developer affordances are visible. False until [initialize].
  bool get enabled => _enabled;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(kDeveloperModeKey) ?? false;
  }

  /// Re-read the flag from disk. Called after a settings import, which
  /// writes the raw pref through the registry behind this service's back.
  Future<void> reload() => initialize();

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kDeveloperModeKey, value);
    LogService.instance
        .log('DeveloperMode', value ? 'enabled' : 'disabled');
  }

  /// Test seam: set the in-memory flag without touching SharedPreferences.
  void debugSet(bool value) => _enabled = value;
}
