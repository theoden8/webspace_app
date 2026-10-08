import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/app_prefs.dart';

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

  /// Whether developer affordances are visible. False until [initialize].
  bool get enabled => AppPref.developerMode.value;

  Future<void> initialize() async {
    AppPref.developerMode.load(await SharedPreferences.getInstance());
    await BackgroundLog.instance.setRecording(on: enabled);
  }

  /// Called after a settings import, so the background log follows the
  /// imported flag.
  Future<void> reload() => initialize();

  Future<void> setEnabled({required bool on}) async {
    if (enabled == on) return;
    await AppPref.developerMode.set(on);
    LogTag.developerMode.debug(on ? 'enabled' : 'disabled');
    // DEVTOOLS-012: the background log exists only while developer mode is
    // on; turning it off deletes what was recorded.
    await BackgroundLog.instance.setRecording(on: on);
  }

  /// Test seam: set the in-memory flag without touching SharedPreferences.
  void debugSet({required bool on}) =>
      AppPref.developerMode.debugValue = on;
}
