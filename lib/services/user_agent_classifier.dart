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
const int kDefaultFirefoxMajorVersion = 151;

/// The OS descriptor (parenthetical token) for each Firefox desktop UA.
const String kFirefoxLinuxPlatformToken = 'X11; Linux x86_64';
const String kFirefoxMacosPlatformToken = 'Macintosh; Intel Mac OS X 10_15_7';
const String kFirefoxWindowsPlatformToken = 'Windows NT 10.0; Win64; x64';

/// Render a Firefox version number (e.g. `"151.0"`) from a [major] version.
/// Firefox freezes the minor at `.0` in the UA regardless of point release.
String firefoxVersionString(int major) => '$major.0';

/// Build a Firefox UA string for an OS [platformToken] (the parenthetical
/// system descriptor, e.g. `"X11; Linux x86_64"`) at the given [version]
/// (e.g. `"151.0"`). Single source of truth for the rendered UA shape, used
/// both for the canonical constants below and by [FirefoxUserAgentService]
/// to render UAs at the scraped current version.
String buildFirefoxUserAgent(String platformToken, String version) =>
    'Mozilla/5.0 ($platformToken; rv:$version) Gecko/20100101 Firefox/$version';

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
