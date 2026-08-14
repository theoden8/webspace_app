import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/demo_data.dart' show isDemoMode;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

class DiagSeedData {
  final List<WebViewModel> sites;
  final int currentIndex;

  const DiagSeedData({required this.sites, required this.currentIndex});
}

/// Launch-time site seeding for the adb-driven white-screen tier
/// (INTEG-011). The lifecycle scenarios (warm start, activity recreation,
/// bfcache back navigation) drive the real APK from outside the process,
/// where the in-process test's SharedPreferences mocking does not exist,
/// so the harness passes a base64 JSON site list as an intent extra and
/// the app seeds itself before the first prefs read.
///
/// Debug builds only: the call is gated on [kDebugMode] and the Kotlin
/// side refuses the extra on non-debuggable builds, so a release build
/// never honors it. Seeding enables demo mode, so nothing from the run
/// is persisted past the seeded values themselves.
class DiagSeed {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/shortcuts');

  /// Decode a base64 `{"sites":[{"name":...,"url":...}],"currentIndex":N}`
  /// seed. siteIds are freshly generated each launch so state keyed by
  /// siteId (cookies, nav-state capture, containers) from a previous
  /// harness run can never bleed into this one.
  static DiagSeedData parse(String encoded) {
    final obj =
        jsonDecode(utf8.decode(base64.decode(encoded))) as Map<String, dynamic>;
    final rawSites = obj['sites'] as List<dynamic>? ?? const [];
    final sites = <WebViewModel>[
      for (final raw in rawSites)
        WebViewModel(
          initUrl: (raw as Map<String, dynamic>)['url'] as String,
          name: raw['name'] as String? ?? 'Diag',
        ),
    ];
    if (sites.isEmpty) {
      throw const FormatException('diag seed has no sites');
    }
    final currentIndex = obj['currentIndex'] as int? ?? 0;
    if (currentIndex < 0 || currentIndex >= sites.length) {
      throw RangeError('currentIndex $currentIndex out of range '
          '(${sites.length} sites)');
    }
    return DiagSeedData(sites: sites, currentIndex: currentIndex);
  }

  /// Reads the `ws_diag_seed` launch-intent extra and, when present,
  /// replaces the persisted site list with the seeded one and enables
  /// demo mode. Returns whether a seed was applied. Must complete before
  /// the page state loads models from prefs.
  static Future<bool> applyFromLaunchIntent() async {
    if (!kDebugMode) return false;
    String? encoded;
    try {
      encoded = await _channel.invokeMethod<String>('getDiagSeed');
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
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
    await prefs.setInt('currentIndex', seed.currentIndex);
    await prefs.setBool('showUrlBar', false);
    isDemoMode = true;
    LogService.instance.log('DiagSeed',
        'seeded ${seed.sites.length} sites, currentIndex=${seed.currentIndex}');
    return true;
  }
}
