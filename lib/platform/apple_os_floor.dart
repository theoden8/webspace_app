import 'package:meta/meta.dart';
import 'package:webspace/platform/host_platform.dart';

/// The Apple OS a fork feature needs: the fork writes it behind
/// `#available(iOS x, macOS y, *)` and silently no-ops below it, while the
/// app's deployment floors are iOS 15 and macOS 11.
enum AppleOsFloor {
  /// Per-site containers (`WKWebsiteDataStore(forIdentifier:)`) and per-site
  /// proxies (`proxyConfigurations`).
  stores(ios: 17, macOS: 14),

  /// `WKWebpagePreferences.isLockdownModeEnabled` (ETP-032).
  lockdownMode(ios: 16, macOS: 13);

  const AppleOsFloor({required this.ios, required this.macOS});

  final int ios;
  final int macOS;
}

/// `io.Platform.operatingSystemVersion` reads `Version 16.7.2 (Build
/// 20H115)` on both platforms; the major version decides. An unparseable
/// string counts as below the floor: going without the feature is the safe
/// side.
bool appleOsMeetsFloor(
  String operatingSystemVersion, {
  required bool isIOS,
  required AppleOsFloor floor,
}) {
  final match = RegExp(r'(\d+)(?:\.\d+)*').firstMatch(operatingSystemVersion);
  if (match == null) return false;
  final major = int.tryParse(match.group(1)!) ?? 0;
  return major >= (isIOS ? floor.ios : floor.macOS);
}

/// Whether this host's webviews take a per-site Lockdown Mode (ETP-032). No
/// other engine the app runs on has one: Android WebView has no such mode and
/// WPE WebKit exposes none.
bool get hostHasLockdownMode =>
    debugHostHasLockdownMode ??
    ((hostIsIOS || hostIsMacOS) &&
        appleOsMeetsFloor(hostOperatingSystemVersion,
            isIOS: hostIsIOS, floor: AppleOsFloor.lockdownMode));

@visibleForTesting
bool? debugHostHasLockdownMode;
