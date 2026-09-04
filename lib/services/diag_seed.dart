import 'dart:convert';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/demo_data.dart' show isDemoMode;
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/repaint_suppression.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

class DiagSeedData {
  final List<WebViewModel> sites;

  const DiagSeedData({required this.sites});
}

/// Launch-time site seeding for the externally-driven test tiers
/// (INTEG-011/012). The lifecycle scenarios (warm start, activity
/// recreation, bfcache back navigation, background refresh) drive the
/// real app from outside the process, where the in-process test's
/// SharedPreferences mocking does not exist, so the harness passes a
/// base64 JSON site list (Android intent extra / `WS_DIAG_SEED` env)
/// and the app seeds itself before the first prefs read.
///
/// Debug builds only: the call is gated on [kDebugMode] and the Kotlin
/// side refuses the extra on non-debuggable builds, so a release build
/// never honors it. Seeding enables demo mode, so nothing from the run
/// is persisted past the seeded values themselves.
class DiagSeed {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/shortcuts');

  /// Decode a base64 `{"sites":[{"name":...,"url":...,"siteId":...}]}`
  /// seed. A site entry may carry an explicit siteId: the harness needs a
  /// known id to activate the site through the production pinned-shortcut
  /// `siteId` extra (a plain cold start lands on the webspace picker with
  /// no site selected — the persisted currentIndex is never read back).
  /// The harness keeps ids unique per run so state keyed by siteId
  /// (cookies, nav-state capture, containers) cannot bleed across runs;
  /// entries without one get a fresh generated id.
  static DiagSeedData parse(String encoded) {
    final obj =
        jsonDecode(utf8.decode(base64.decode(encoded))) as Map<String, dynamic>;
    final rawSites = obj['sites'] as List<dynamic>? ?? const [];
    final sites = <WebViewModel>[
      for (final raw in rawSites)
        WebViewModel(
          siteId: (raw as Map<String, dynamic>)['siteId'] as String?,
          initUrl: raw['url'] as String,
          name: raw['name'] as String? ?? 'Diag',
          notificationsEnabled: raw['notificationsEnabled'] as bool? ?? false,
        ),
    ];
    if (sites.isEmpty) {
      throw const FormatException('diag seed has no sites');
    }
    return DiagSeedData(sites: sites);
  }

  /// How many reloads the launch intent asked the harness to issue, drained
  /// on read so a later resume does not repeat them.
  ///
  /// The refresh funnel is only reachable from the overflow menu, which adb
  /// cannot drive, and the reload path is the one BUG-001 was reported on.
  /// Debug builds only, like the seed.
  static Future<int?> takeReloadRequest() async {
    if (!kDebugMode) return null;
    String? spec;
    try {
      spec = await _channel.invokeMethod<String>('getDiagReload');
    } on MissingPluginException {
      spec = null;
    } on PlatformException {
      spec = null;
    }
    spec ??= hostEnvironment['WS_DIAG_RELOAD'];
    if (spec == null || spec.trim().isEmpty) return null;
    return int.tryParse(spec.trim());
  }

  /// Reads the seed from the `ws_diag_seed` launch-intent extra (Android)
  /// or the `WS_DIAG_SEED` process environment (iOS/macOS: `simctl launch`
  /// forwards `SIMCTL_CHILD_`-prefixed host variables, so a future simctl
  /// driver reuses this transport unchanged) and, when present, replaces
  /// the persisted site list with the seeded one and enables demo mode.
  /// Returns whether a seed was applied. Must complete before the page
  /// state loads models from prefs.
  static Future<bool> applyFromLaunch() async {
    if (!kDebugMode) return false;
    String? encoded;
    try {
      encoded = await _channel.invokeMethod<String>('getDiagSeed');
    } on MissingPluginException {
      encoded = null;
    } on PlatformException {
      encoded = null;
    }
    encoded ??= hostEnvironment['WS_DIAG_SEED'];
    // Independent of the site seed: a scenario may want the suppression
    // without reseeding, and an unparseable seed must not silently leave a
    // previous run's suppression armed.
    String? suppress;
    try {
      suppress = await _channel.invokeMethod<String>('getDiagRepaintSuppression');
    } on MissingPluginException {
      suppress = null;
    } on PlatformException {
      suppress = null;
    }
    suppress ??= hostEnvironment['WS_DIAG_SUPPRESS_REPAINT'];
    RepaintSuppression.setFromSpec(suppress);
    if (RepaintSuppression.triggers.isNotEmpty) {
      LogService.instance.log('DiagSeed',
          'repaint triggers suppressed: '
          '${RepaintSuppression.triggers.join(', ')}');
    }
    if (encoded == null || encoded.isEmpty) return false;
    final DiagSeedData seed;
    try {
      seed = parse(encoded);
    } catch (e) {
      LogService.instance
          .log('DiagSeed', 'ignoring unparseable seed: $e', level: LogLevel.error);
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('webViewModels',
        seed.sites.map((s) => jsonEncode(s.toJson())).toList());
    await prefs.remove('webspaces');
    await prefs.setString('selectedWebspaceId', kAllWebspaceId);
    await prefs.setBool('showUrlBar', false);
    // The harness activates sites through the shortcut path, which enters
    // fullscreen by default; the first immersive entry pops Android's
    // "viewing full screen" education bubble, whose screen-wide 50% dim
    // corrupts every pixel sample.
    await prefs.setBool('fullscreenOnShortcut', false);
    // Turn the SurfaceDiag repaint trace on for the run: it is gated on
    // developer mode so an ordinary session does not spend its log ring on
    // it, but the externally-driven tiers exist precisely to see which
    // repaint path fired, and a pixel verdict alone cannot say that.
    await prefs.setBool(kDeveloperModeKey, true);
    isDemoMode = true;
    LogService.instance.log('DiagSeed',
        'seeded ${seed.sites.length} sites: '
        '${seed.sites.map((s) => s.siteId).join(', ')}');
    return true;
  }
}
