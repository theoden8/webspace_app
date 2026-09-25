import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/pref_read.dart';

const String kExperimentalTorKey = 'experimentalTor';
const String kExperimentalProxyRouterKey = 'experimentalProxyRouter';
const String kExperimentalLinkRoutingKey = 'experimentalLinkRouting';

/// A feature that ships before it is finished (DEVTOOLS-011): reachable only
/// with developer mode on and its own switch on in App Settings'
/// Experimental group.
enum ExperimentalFeature {
  /// The embedded Tor client (TOR-007). On by default: before this switch
  /// existed developer mode alone opened Tor, and a user who had it on must
  /// not find their Tor sites blocked by an upgrade.
  tor(kExperimentalTorKey, defaultOn: true),

  /// Android's per-site proxy router (PROXY-013). On by default for the same
  /// reason as [tor]: developer mode alone ran it before this switch existed.
  proxyRouter(kExperimentalProxyRouterKey, defaultOn: true),

  /// A site handing a link it opens to the site that claims it
  /// (link-intent-routing LIR-013 to LIR-017). Off by default: it is new.
  linkRouting(kExperimentalLinkRoutingKey, defaultOn: false);

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
