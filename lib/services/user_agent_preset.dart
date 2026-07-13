/// Per-site User-Agent presets: persist the *intent* (which browser shape
/// the user picked), not the rendered string.
///
/// A UA string persisted verbatim goes stale in two ways: the version
/// freezes (`Firefox/147` in a world of 152+) and the grammar rots when a
/// generator bug is fixed or upstream changes shape (the pre-#410
/// randomizer emitted an iPhone token inside the Gecko desktop grammar —
/// a combination no real browser sends, which x.com flags as an embedded
/// webview and bounces to `x-safari-https://`). Storing a preset and
/// rendering at webview-creation time makes every builder fix and version
/// refresh apply retroactively to all sites; free-text UAs stay untouched
/// (`uaPreset == null`).
library;

import 'package:webspace/services/user_agent_classifier.dart';

enum UserAgentPreset {
  firefoxLinux,
  firefoxWindows,
  firefoxMacos,
  firefoxAndroid,
  firefoxIos,
}

/// Inverse of [UserAgentPreset.name] for JSON rehydration. Unknown names
/// (from a newer app's backup) resolve to null — the site falls back to
/// its stored string, treated as custom.
UserAgentPreset? userAgentPresetFromName(String? name) {
  if (name == null) return null;
  for (final p in UserAgentPreset.values) {
    if (p.name == name) return p;
  }
  return null;
}

/// Render [preset] at [version] (e.g. `"152.0"`) using the same builders
/// the randomize pool uses.
String renderUserAgentPreset(UserAgentPreset preset, String version) {
  switch (preset) {
    case UserAgentPreset.firefoxLinux:
      return buildFirefoxUserAgent(kFirefoxLinuxPlatformToken, version);
    case UserAgentPreset.firefoxWindows:
      return buildFirefoxUserAgent(kFirefoxWindowsPlatformToken, version);
    case UserAgentPreset.firefoxMacos:
      return buildFirefoxUserAgent(kFirefoxMacosPlatformToken, version);
    case UserAgentPreset.firefoxAndroid:
      return buildFirefoxAndroidUserAgent(version);
    case UserAgentPreset.firefoxIos:
      return buildFirefoxIosUserAgent(version);
  }
}

// Every shape any WebSpace generator has ever emitted, version-agnostic
// (`rv:`/`Firefox/` must agree — a mismatch means a hand-edited string we
// must not claim). Ordered legacy-last so current shapes match first.
//
// The desktop alternation accepts both the correct macOS freeze ("10.15")
// and the Chrome-grammar token ("10_15_7") old builds emitted.
final RegExp _desktopShape = RegExp(
    r'^Mozilla/5\.0 \((X11; Linux x86_64|Windows NT 10\.0; Win64; x64|'
    r'Macintosh; Intel Mac OS X (?:10\.15|10_15_7)); rv:(\d+\.\d+)\) '
    r'Gecko/20100101 Firefox/(\d+\.\d+)$');

// Current Firefox-for-Android shape: Gecko trail equals the version.
final RegExp _androidShape = RegExp(
    r'^Mozilla/5\.0 \(Android \d+; Mobile; rv:(\d+\.\d+)\) '
    r'Gecko/\1 Firefox/\1$');

// Pre-#410 randomizer glued the desktop trail onto the Android token.
final RegExp _androidLegacyShape = RegExp(
    r'^Mozilla/5\.0 \(Android \d+; Mobile; rv:(\d+\.\d+)\) '
    r'Gecko/20100101 Firefox/\1$');

// FxiOS at any frozen OS version; accepts both the correct Safari/604.1
// tail and the Safari/605.1.15 tail earlier builds emitted.
final RegExp _fxiosShape = RegExp(
    r'^Mozilla/5\.0 \(iPhone; CPU iPhone OS \d+_\d+ like Mac OS X\) '
    r'AppleWebKit/605\.1\.15 \(KHTML, like Gecko\) '
    r'FxiOS/\d+\.\d+ Mobile/15E148 Safari/60(?:4\.1|5\.1\.15)$');

// The impossible hybrid the pre-#410 randomizer emitted: iPhone token
// inside the desktop Gecko grammar. The frozen `20100101` trail keeps
// this from claiming Mozilla's real Gecko-on-iOS browser, whose trail
// equals the version.
final RegExp _iosLegacyShape = RegExp(
    r'^Mozilla/5\.0 \(iPhone; CPU iPhone OS [\d_]+ like Mac OS X; '
    r'rv:(\d+\.\d+)\) Gecko/20100101 Firefox/\1$');

/// Returns the preset that (some version of) the WebSpace generator would
/// have rendered [ua] from, or null for anything a user could plausibly
/// have typed or pasted themselves. Exact-shape matching only: a string
/// that fully matches a generated grammar came from the generator, so
/// re-rendering it at the current version is a repair, not an override.
UserAgentPreset? recognizeGeneratedUserAgent(String ua) {
  final desktop = _desktopShape.firstMatch(ua);
  if (desktop != null) {
    if (desktop.group(2) != desktop.group(3)) return null;
    final token = desktop.group(1)!;
    if (token.startsWith('X11')) return UserAgentPreset.firefoxLinux;
    if (token.startsWith('Windows')) return UserAgentPreset.firefoxWindows;
    return UserAgentPreset.firefoxMacos;
  }
  if (_androidShape.hasMatch(ua) || _androidLegacyShape.hasMatch(ua)) {
    return UserAgentPreset.firefoxAndroid;
  }
  if (_fxiosShape.hasMatch(ua) || _iosLegacyShape.hasMatch(ua)) {
    return UserAgentPreset.firefoxIos;
  }
  return null;
}
