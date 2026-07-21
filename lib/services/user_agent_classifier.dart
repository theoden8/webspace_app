/// User-Agent classification for desktop-mode inference.
///
/// Rather than carry an explicit per-site "desktop mode" toggle, we derive
/// the mode from the per-site User-Agent string. If the UA looks like a
/// mobile browser (contains an "Android"/"iPhone"/"Mobile" token), the
/// site renders in mobile mode (preferredContentMode RECOMMENDED, no
/// touch-spoofing shim). If it looks like a desktop browser (no mobile
/// markers), the site renders in desktop mode.
///
/// This collapses two settings (UA + content-mode) into one. The user's
/// only knob is the UA field; everything else follows from it.
library;

/// Substrings whose presence in a UA marks it as a mobile browser. Order
/// is irrelevant — we check `contains` for any of them.
const List<String> _mobileMarkers = [
  'android',
  'iphone',
  'ipad',
  'ipod',
  'mobile', // catches "Mobile Safari", "Opera Mobi", etc.
  'blackberry',
  'windows phone',
  'opera mini',
  'webos',
  'kindle',
];

/// Returns `true` if [ua] looks like a desktop browser User-Agent.
///
/// Empty or null UAs return `false` — an empty UA string falls back to the
/// underlying mobile WebView's default UA, which is itself mobile, so we
/// classify it as mobile.
bool isDesktopUserAgent(String? ua) {
  if (ua == null || ua.isEmpty) return false;
  final lower = ua.toLowerCase();
  for (final marker in _mobileMarkers) {
    if (lower.contains(marker)) return false;
  }
  return true;
}

/// The rendering/JS engine a UA string claims. Drives the engine-consistent
/// navigator-identity shim (`user_agent_identity_shim.dart`): `navigator`
/// fields like `vendor`, `productSub`, `oscpu`, and `buildID` are set by the
/// engine, not the OS, so a spoofed UA whose engine disagrees with the
/// underlying WebView (e.g. a Gecko UA on iOS WebKit) leaks unless these
/// are made to match the *claimed* engine.
enum UaEngine { gecko, webkit, blink, unknown }

final RegExp _geckoBuildToken = RegExp(r'gecko/\d');

/// Infer the JS engine a [ua] claims. iOS mandates WebKit, so any Apple
/// mobile-browser brand token (FxiOS/CriOS/EdgiOS/OPiOS) classifies as
/// [UaEngine.webkit] regardless of brand. Real Gecko carries a `Gecko/<digits>`
/// build token plus `Firefox/`; every WebKit/Blink UA only carries the
/// `(KHTML, like Gecko)` marker (no `Gecko/<digits>`). Returns
/// [UaEngine.unknown] for empty or unrecognized strings (the shim then
/// injects nothing).
UaEngine inferUaEngine(String? ua) {
  if (ua == null || ua.isEmpty) return UaEngine.unknown;
  final lower = ua.toLowerCase();
  final hasAppleWebKit = lower.contains('applewebkit/');
  if (!hasAppleWebKit &&
      _geckoBuildToken.hasMatch(lower) &&
      lower.contains('firefox/')) {
    return UaEngine.gecko;
  }
  if (hasAppleWebKit) {
    final iosBrand = lower.contains('crios/') ||
        lower.contains('fxios/') ||
        lower.contains('edgios/') ||
        lower.contains('opios/');
    final isBlink = !iosBrand &&
        (lower.contains('chrome/') || lower.contains('chromium/'));
    return isBlink ? UaEngine.blink : UaEngine.webkit;
  }
  return UaEngine.unknown;
}

/// Which desktop-platform substring a UA carries. Used by the JS shim to
/// emit the matching `navigator.platform` value.
enum DesktopUaPlatform { linux, macos, windows }

/// Infer the desktop platform identifier from a desktop-shaped [ua].
///
/// Defaults to [DesktopUaPlatform.linux] when no match is found — that's
/// the safest "desktop, but not specifically Windows or Mac" fallback and
/// matches what Chrome for Android emits when the user taps "Request
/// desktop site". Caller is expected to have already checked
/// [isDesktopUserAgent]; the return value is meaningless for mobile UAs.
DesktopUaPlatform inferDesktopUaPlatform(String ua) {
  final lower = ua.toLowerCase();
  if (lower.contains('macintosh') || lower.contains('mac os x')) {
    return DesktopUaPlatform.macos;
  }
  if (lower.contains('windows nt')) {
    return DesktopUaPlatform.windows;
  }
  return DesktopUaPlatform.linux;
}

/// Value to expose as `navigator.platform` for a given inferred desktop
/// platform. Matches what real Firefox/Chrome desktop instances emit.
String navigatorPlatformFor(DesktopUaPlatform p) {
  switch (p) {
    case DesktopUaPlatform.linux:
      return 'Linux x86_64';
    case DesktopUaPlatform.macos:
      return 'MacIntel';
    case DesktopUaPlatform.windows:
      return 'Win32';
  }
}

/// Major Firefox version baked into the build as the offline fallback.
/// [FirefoxUserAgentService] overrides it at runtime once it scrapes the
/// current release version from Firefox source; until then — and whenever
/// the scrape fails or the network is unreachable — UA strings render with
/// this version. It also acts as a floor: a scraped version older than this
/// is ignored, so app upgrades never regress the UA.
const int kDefaultFirefoxMajorVersion = 152;

/// The OS descriptor (parenthetical token) for each Firefox desktop UA.
/// Values mirror gecko's `nsHttpHandler::InitUserAgentComponents`
/// (netwerk/protocol/http/nsHttpHandler.cpp): Windows is hardcoded to
/// "NT 10.0; Win64; x64", macOS is frozen at "10.15" (dot-separated —
/// the underscore form `10_15_7` is Chrome/WebKit grammar and marks the
/// string as fake in a Firefox UA), Linux always reports "X11".
/// `test/js/firefox_ua_upstream.test.js` scrapes that source to catch
/// drift.
const String kFirefoxLinuxPlatformToken = 'X11; Linux x86_64';
const String kFirefoxMacosPlatformToken = 'Macintosh; Intel Mac OS X 10.15';
const String kFirefoxWindowsPlatformToken = 'Windows NT 10.0; Win64; x64';

/// Render a Firefox version number (e.g. `"151.0"`) from a [major] version.
/// Firefox freezes the minor at `.0` in the UA regardless of point release.
String firefoxVersionString(int major) => '$major.0';

/// Build a Firefox **desktop** UA string for an OS [platformToken] (the
/// parenthetical system descriptor, e.g. `"X11; Linux x86_64"`) at the given
/// [version] (e.g. `"151.0"`). Single source of truth for the desktop UA
/// shape, used both for the canonical constants below and by
/// [FirefoxUserAgentService] to render UAs at the scraped current version.
String buildFirefoxUserAgent(String platformToken, String version) =>
    'Mozilla/5.0 ($platformToken; rv:$version) Gecko/20100101 Firefox/$version';

/// OS token Firefox for Android emits in its UA. Gecko reports the real
/// Android major version for OS >= 10 and only spoofs older devices up to
/// "Android 10" (nsHttpHandler.cpp, bug 1876742), so a static UA should
/// carry a current major, not 10. Pin the newest stable Android release —
/// consistent with rendering the newest Firefox version — and bump it
/// alongside [kDefaultFirefoxMajorVersion].
const String kFirefoxAndroidOsToken = 'Android 16';

/// Firefox-for-Android UA. Differs from desktop in two ways that matter to
/// servers sniffing the string: the Gecko trail equals the version (desktop
/// freezes it at `20100101`), and the OS token carries the Android major
/// ([kFirefoxAndroidOsToken]).
String buildFirefoxAndroidUserAgent(String version) =>
    'Mozilla/5.0 ($kFirefoxAndroidOsToken; Mobile; rv:$version) '
    'Gecko/$version Firefox/$version';

/// Fixed tokens for the Firefox-for-iOS (FxiOS) UA. iOS mandates WebKit, so
/// Firefox there is a Safari-shaped UA carrying an `FxiOS/<version>` marker
/// rather than a Gecko build. Values mirror firefox-ios's
/// `UserAgentBuilder.defaultMobileUserAgent`
/// (BrowserKit/Sources/Shared/UserAgent.swift): the OS version is frozen
/// upstream (`OS 18_7`), and the trailing Safari bit is `Safari/604.1` —
/// the same token Mobile Safari ends with — NOT the `605.1.15` WebKit
/// build number, which upstream only uses in its desktop-mode UA.
/// `test/js/firefox_ua_upstream.test.js` scrapes that source to catch
/// drift.
const String _kFxiosOsToken = 'iPhone; CPU iPhone OS 18_7 like Mac OS X';
const String _kFxiosWebKit = 'AppleWebKit/605.1.15 (KHTML, like Gecko)';
const String _kFxiosMobileBuild = 'Mobile/15E148';
const String _kFxiosSafari = 'Safari/604.1';

/// Firefox-for-iOS (FxiOS) UA at the given [version] (e.g. `"151.0"`).
String buildFirefoxIosUserAgent(String version) =>
    'Mozilla/5.0 ($_kFxiosOsToken) $_kFxiosWebKit '
    'FxiOS/$version $_kFxiosMobileBuild $_kFxiosSafari';

/// Canonical Firefox desktop UA strings at [kDefaultFirefoxMajorVersion],
/// exposed as named constants so tests have stable fixtures and so any
/// caller wanting a known-good desktop UA without the runtime service can
/// reach one. Built from the same shape [buildFirefoxUserAgent] renders.
const String _kDefaultFirefoxVersion = '$kDefaultFirefoxMajorVersion.0';
const String firefoxLinuxDesktopUserAgent =
    'Mozilla/5.0 ($kFirefoxLinuxPlatformToken; rv:$_kDefaultFirefoxVersion) '
    'Gecko/20100101 Firefox/$_kDefaultFirefoxVersion';
const String firefoxMacosDesktopUserAgent =
    'Mozilla/5.0 ($kFirefoxMacosPlatformToken; rv:$_kDefaultFirefoxVersion) '
    'Gecko/20100101 Firefox/$_kDefaultFirefoxVersion';
const String firefoxWindowsDesktopUserAgent =
    'Mozilla/5.0 ($kFirefoxWindowsPlatformToken; rv:$_kDefaultFirefoxVersion) '
    'Gecko/20100101 Firefox/$_kDefaultFirefoxVersion';
