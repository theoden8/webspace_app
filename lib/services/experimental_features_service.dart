import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/app_prefs.dart';

/// A feature that ships before it is finished (DEVTOOLS-011): reachable only
/// with developer mode on and its own switch on in App Settings'
/// Experimental group.
enum ExperimentalFeature {
  /// Android's per-site proxy router (PROXY-013). On by default: developer
  /// mode alone ran it before this switch existed, and a user who had it on
  /// must not lose it to an upgrade.
  proxyRouter(AppPref.experimentalProxyRouter),

  /// A site's icon taken only from the site: no third-party icon service, and
  /// on Android the links its page declares, fetched as on every other
  /// platform, in place of the icon WebView reports (icon-fetching ICON-014).
  /// New, so off by default.
  siteIconsOnly(AppPref.experimentalSiteIconsOnly),

  /// Android's texture-layer webview composition (PAUSE-032). Off by
  /// default: every release before it drew pages with hybrid composition.
  textureRendering(AppPref.experimentalTextureRendering),

  /// Several pages per site (inactive-tabs TAB-012). Off by default: it is
  /// new. With it off a site shows its one page, as before tabs existed.
  siteTabs(AppPref.experimentalSiteTabs),

  /// Tor sites through a tor already running on the device, with per-site
  /// SOCKS credentials (tor-proxy TOR-025). Off by default: it is new.
  /// Applies without a relaunch through `TorService.runtimeChoiceChanged`.
  externalTor(AppPref.experimentalExternalTor);

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

  Future<void> setSwitch(ExperimentalFeature feature, bool value) async {
    if (switchOn(feature) == value) return;
    await feature.pref.set(value);
    LogTag.experimental.debug('${feature.name} ${value ? 'on' : 'off'}');
  }

  /// Test seam: set a switch without touching SharedPreferences.
  void debugSet(ExperimentalFeature feature, bool value) =>
      feature.pref.debugValue = value;
}
