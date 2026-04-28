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

/// Canonical Firefox desktop UA strings, exposed for the legacy
/// `desktopMode`-field migration in `WebViewModel.fromJson`. Versioned to
/// stay reasonably close to current Firefox; the rendered shape matches
/// the project's existing `generateRandomUserAgent()` output.
const String firefoxLinuxDesktopUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64; rv:147.0) Gecko/20100101 Firefox/147.0';
const String firefoxMacosDesktopUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7; rv:147.0) '
    'Gecko/20100101 Firefox/147.0';
const String firefoxWindowsDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:147.0) '
    'Gecko/20100101 Firefox/147.0';
