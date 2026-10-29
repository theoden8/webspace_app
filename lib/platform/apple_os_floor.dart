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
  webExtensions(ios: (major: 18, minor: 4), macOS: (major: 15, minor: 4)),

  /// `SCContentSharingPicker`, the system picker a real screen share starts
  /// from (SHARE-018). macOS only.
  screenSharePicker(ios: null, macOS: (major: 14, minor: 0));

  const AppleOsFloor({required this.ios, required this.macOS});

  /// Null for a feature with no iOS form at all.
  final AppleOsVersion? ios;
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
  if (need == null) return false;
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

/// Whether this host can share its real screen with a page (SHARE-018):
/// Android through `MediaProjection`, Linux through the desktop portal's
/// ScreenCast, macOS 14 and later through the system's content picker. Not
/// iOS, where sharing more than the app itself takes a broadcast extension.
bool get hostSharesScreen =>
    debugHostSharesScreen ??
    (hostIsAndroid ||
        hostIsLinux ||
        (hostIsMacOS &&
            appleOsMeetsFloor(hostOperatingSystemVersion,
                isIOS: false, floor: AppleOsFloor.screenSharePicker)));

@visibleForTesting
bool? debugHostSharesScreen;
