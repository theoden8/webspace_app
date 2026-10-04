import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/pref_read.dart';

const String kExperimentalProxyRouterKey = 'experimentalProxyRouter';
const String kExperimentalSiteIconsOnlyKey = 'experimentalSiteIconsOnly';
const String kExperimentalTextureRenderingKey = 'experimentalTextureRendering';
const String kExperimentalSiteTabsKey = 'experimentalSiteTabs';
const String kExperimentalExternalTorKey = 'experimentalExternalTor';

/// A feature that ships before it is finished (DEVTOOLS-011): reachable only
/// with developer mode on and its own switch on in App Settings'
/// Experimental group.
enum ExperimentalFeature {
  /// Android's per-site proxy router (PROXY-013). On by default: developer
  /// mode alone ran it before this switch existed, and a user who had it on
  /// must not lose it to an upgrade.
  proxyRouter(kExperimentalProxyRouterKey, defaultOn: true),

  /// A site's icon taken only from the site: no third-party icon service, and
  /// on Android the links its page declares, fetched as on every other
  /// platform, in place of the icon WebView reports (icon-fetching ICON-014).
  /// New, so off by default.
  siteIconsOnly(kExperimentalSiteIconsOnlyKey, defaultOn: false),

  /// Android's texture-layer webview composition (PAUSE-032). Off by
  /// default: every release before it drew pages with hybrid composition.
  textureRendering(kExperimentalTextureRenderingKey, defaultOn: false),

  /// Several pages per site (inactive-tabs TAB-012). Off by default: it is
  /// new. With it off a site shows its one page, as before tabs existed.
  siteTabs(kExperimentalSiteTabsKey, defaultOn: false),

  /// Tor sites through a tor already running on the device, with per-site
  /// SOCKS credentials (tor-proxy TOR-025). Off by default: it is new.
  /// Applies without a relaunch through `TorService.runtimeChoiceChanged`.
  externalTor(kExperimentalExternalTorKey, defaultOn: false);

  const ExperimentalFeature(this.prefKey, {required this.defaultOn});

  final String prefKey;
  final bool defaultOn;
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
/// [DeveloperModeService]: one reader for every screen, re-read after an
/// import writes the raw prefs behind its cache.
class ExperimentalFeaturesService {
  ExperimentalFeaturesService._();
  static final ExperimentalFeaturesService instance =
      ExperimentalFeaturesService._();

  final Map<ExperimentalFeature, bool> _switches = {
    for (final f in ExperimentalFeature.values) f: f.defaultOn,
  };

  /// The feature's own switch, whatever developer mode says.
  bool switchOn(ExperimentalFeature feature) => _switches[feature]!;

  /// Whether [feature] is reachable now.
  bool isEnabled(ExperimentalFeature feature) => experimentalFeatureEnabled(
        developerMode: DeveloperModeService.instance.enabled,
        switchOn: switchOn(feature),
      );

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    for (final f in ExperimentalFeature.values) {
      _switches[f] = readPrefAs<bool>(prefs, f.prefKey) ?? f.defaultOn;
    }
  }

  Future<void> reload() => initialize();

  Future<void> setSwitch(ExperimentalFeature feature, bool value) async {
    if (_switches[feature] == value) return;
    _switches[feature] = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(feature.prefKey, value);
    LogService.instance.log(
        'Experimental', '${feature.name} ${value ? 'on' : 'off'}');
  }

  /// Test seam: set a switch without touching SharedPreferences.
  void debugSet(ExperimentalFeature feature, bool value) =>
      _switches[feature] = value;
}
