import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/app_prefs.dart';

/// A feature that ships before it is finished (DEVTOOLS-011): reachable only
/// with developer mode on and its own switch on in App Settings'
/// Experimental group.
enum ExperimentalFeature {
  /// Android's texture-layer webview composition (PAUSE-032). Off by
  /// default: every release before it drew pages with hybrid composition.
  textureRendering(AppPref.experimentalTextureRendering),

  /// The grouped site launcher, leaving the existing interface as default.
  folderLibrary(AppPref.experimentalFolderLibrary),

  /// A page's sign-in window, opened by the user's tap, shown as a real popup
  /// so its result reaches the page (nested-url-blocking NESTED-014). New, so
  /// off by default.
  signInPopups(AppPref.experimentalSignInPopups),

  /// Web extensions per site, where WebKit runs them (WEBEXT-001). New, so
  /// off by default.
  webExtensions(AppPref.experimentalWebExtensions),

  /// A search of addons.mozilla.org on the Extensions screen, in a build
  /// from outside the App Store (WEBEXT-019). New, so off by default.
  extensionSearch(AppPref.experimentalExtensionSearch),

  /// The menu bar icon on macOS while a close only hides the window
  /// (NOTIF-019); Linux's tray graduated. New, so off by default.
  desktopTray(AppPref.experimentalDesktopTray);

  const ExperimentalFeature(this.pref);

  final AppPref<bool> pref;
}

/// DEVTOOLS-011: a feature is reachable when developer mode and its own
/// switch are both on. The switch narrows developer mode, never widens it, so
/// "is this reachable" still has one answer.
bool experimentalFeatureEnabled({
  required bool developerMode,
  required bool switchOn,
}) =>
    developerMode && switchOn;

/// The per-feature switches of the Experimental group. Same shape as
/// [DeveloperModeService]: one reader for every screen.
class ExperimentalFeaturesService {
  ExperimentalFeaturesService._();
  static final ExperimentalFeaturesService instance =
      ExperimentalFeaturesService._();

  /// The feature's own switch, whatever developer mode says.
  bool switchOn(ExperimentalFeature feature) => feature.pref.value;

  /// Whether [feature] is reachable now.
  bool isEnabled(ExperimentalFeature feature) => experimentalFeatureEnabled(
        developerMode: DeveloperModeService.instance.enabled,
        switchOn: switchOn(feature),
      );

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    for (final f in ExperimentalFeature.values) {
      f.pref.load(prefs);
    }
  }

  Future<void> setSwitch(ExperimentalFeature feature,
      {required bool on}) async {
    if (switchOn(feature) == on) return;
    await feature.pref.set(on);
    LogTag.experimental.debug('${feature.name} ${on ? 'on' : 'off'}');
  }

  /// Test seam: set a switch without touching SharedPreferences.
  void debugSet(ExperimentalFeature feature, {required bool on}) =>
      feature.pref.debugValue = on;
}
