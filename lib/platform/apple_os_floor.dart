import 'package:meta/meta.dart';
import 'package:webspace/platform/host_platform.dart';

/// The Apple OS a fork feature needs: the fork writes it behind
/// `#available(iOS x, macOS y, *)` and silently no-ops below it, while the
/// app's deployment floors are iOS 15 and macOS 11.
enum AppleOsFloor {
  /// Per-site containers (`WKWebsiteDataStore(forIdentifier:)`) and per-site
  /// proxies (`proxyConfigurations`).
  stores(ios: (major: 17, minor: 0), macOS: (major: 14, minor: 0)),

  /// `WKWebpagePreferences.isLockdownModeEnabled` (ETP-032).
  lockdownMode(ios: (major: 16, minor: 0), macOS: (major: 13, minor: 0)),

  /// `WKWebExtension` and its controller (WEBEXT-001).
  webExtensions(ios: (major: 18, minor: 4), macOS: (major: 15, minor: 4));

  const AppleOsFloor({required this.ios, required this.macOS});

  final AppleOsVersion ios;
  final AppleOsVersion macOS;
}

typedef AppleOsVersion = ({int major, int minor});

/// `io.Platform.operatingSystemVersion` reads `Version 16.7.2 (Build
/// 20H115)` on both platforms; the major and minor versions decide. An
/// unparseable string counts as below the floor: going without the feature
/// is the safe side.
bool appleOsMeetsFloor(
  String operatingSystemVersion, {
  required bool isIOS,
  required AppleOsFloor floor,
}) {
  final match = RegExp(r'(\d+)(?:\.(\d+))?').firstMatch(operatingSystemVersion);
  if (match == null) return false;
  final major = int.tryParse(match.group(1)!) ?? 0;
  final minor = int.tryParse(match.group(2) ?? '0') ?? 0;
  final need = isIOS ? floor.ios : floor.macOS;
  return major > need.major || (major == need.major && minor >= need.minor);
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

/// Whether this host's webviews can load web extensions (WEBEXT-001): only
/// WebKit on Apple has `WKWebExtension`.
bool get hostRunsWebExtensions =>
    debugHostRunsWebExtensions ??
    ((hostIsIOS || hostIsMacOS) &&
        appleOsMeetsFloor(hostOperatingSystemVersion,
            isIOS: hostIsIOS, floor: AppleOsFloor.webExtensions));

@visibleForTesting
bool? debugHostRunsWebExtensions;
