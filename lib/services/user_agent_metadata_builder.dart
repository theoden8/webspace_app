/// Per-site User-Agent Client Hints metadata, derived from the spoofed
/// `userAgent` string and wired through to androidx.webkit's
/// `WebSettingsCompat.setUserAgentMetadata` on Android via the fork's
/// [InAppWebViewSettings.userAgentMetadata] field.
///
/// Setting only [InAppWebViewSettings.userAgent] does NOT suppress the
/// `Sec-CH-UA`, `Sec-CH-UA-Mobile`, `Sec-CH-UA-Platform` HTTP request
/// headers or the `navigator.userAgentData` JS surface — Chromium WebView
/// builds those from a separate UA-metadata object that this API overrides.
/// Without an override, a per-site Firefox UA leaks
/// `Sec-CH-UA: "Chromium";v="REAL", Sec-CH-UA-Mobile: ?1,
/// Sec-CH-UA-Platform: "Android"` while the UA string says Firefox-desktop —
/// sites that gate on UA-CH (DDG, anti-bot vendors) keep serving mobile and
/// see a contradictory fingerprint. This builder makes the two consistent.
///
/// The setting is silently dropped on iOS / macOS / Linux: WKWebView and
/// WPE WebKit have no equivalent native API. We still build the metadata
/// on those platforms so backup JSON stays portable.
library;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webspace/services/user_agent_classifier.dart';

/// GREASE entry the W3C UA-CH spec recommends prepending so servers do not
/// hard-code brand-list shape. Mirrors what real Chrome emits today.
BrandVersion _greaseBrand() => BrandVersion(
      brand: 'Not.A/Brand',
      majorVersion: '99',
      fullVersion: '99.0.0.0',
    );

/// Build [UserAgentMetadata] consistent with the spoofed [ua] string.
/// Returns `null` for empty/null UAs (the platform default applies).
///
/// The shape:
/// - `mobile` → false for desktop-shaped UAs, true otherwise.
/// - `platform` → "Linux" / "macOS" / "Windows" / "iOS" / "Android",
///   inferred from the UA via [isDesktopUserAgent] + [inferDesktopUaPlatform]
///   for desktop, or substring match for mobile.
/// - `brandVersionList` → Firefox / Chrome brand entries with the version
///   parsed out of the UA string, plus a GREASE entry. Returns `null` when
///   the UA matches neither (the Android default brand list survives).
/// - `fullVersion` → the recognized brand's full version. `null` for
///   unrecognized UAs.
/// - `architecture` / `bitness` / `model` / `wow64` left null. The per-site
///   anti-fingerprinting shim already covers the JS-side hardware surfaces;
///   synthesizing wire-level values here would manufacture identifying
///   entropy for the same site without privacy benefit.
UserAgentMetadata? buildUserAgentMetadata(String? ua) {
  if (ua == null || ua.isEmpty) return null;

  final desktop = isDesktopUserAgent(ua);
  final platform = _platformFor(ua, desktop);
  final brandList = _brandVersionListFor(ua);

  return UserAgentMetadata(
    brandVersionList: brandList,
    fullVersion: brandList?.last.fullVersion,
    platform: platform,
    mobile: !desktop,
  );
}

String _platformFor(String ua, bool desktop) {
  if (desktop) {
    return switch (inferDesktopUaPlatform(ua)) {
      DesktopUaPlatform.linux => 'Linux',
      DesktopUaPlatform.macos => 'macOS',
      DesktopUaPlatform.windows => 'Windows',
    };
  }
  final lower = ua.toLowerCase();
  if (lower.contains('iphone') ||
      lower.contains('ipad') ||
      lower.contains('ipod')) {
    return 'iOS';
  }
  return 'Android';
}

final RegExp _firefoxVersionRe = RegExp(r'Firefox/(\d+(?:\.\d+)*)');
final RegExp _chromeVersionRe = RegExp(r'Chrome/(\d+(?:\.\d+)*)');

List<BrandVersion>? _brandVersionListFor(String ua) {
  final firefox = _firefoxVersionRe.firstMatch(ua);
  if (firefox != null) {
    final full = firefox.group(1)!;
    final major = full.split('.').first;
    return [
      _greaseBrand(),
      BrandVersion(
        brand: 'Firefox',
        majorVersion: major,
        fullVersion: _padFullVersion(full),
      ),
    ];
  }

  final chrome = _chromeVersionRe.firstMatch(ua);
  if (chrome != null) {
    final full = chrome.group(1)!;
    final major = full.split('.').first;
    final padded = _padFullVersion(full);
    return [
      _greaseBrand(),
      BrandVersion(
        brand: 'Chromium',
        majorVersion: major,
        fullVersion: padded,
      ),
      BrandVersion(
        brand: 'Google Chrome',
        majorVersion: major,
        fullVersion: padded,
      ),
    ];
  }
  return null;
}

/// `Sec-CH-UA-Full-Version-List` carries 4-segment versions
/// (e.g. `137.0.6943.137`). UA strings often only carry the major (Firefox
/// emits `147.0`, Chrome sometimes emits `137.0.0.0`); pad to four so we
/// don't ship a suspiciously short value.
String _padFullVersion(String version) {
  final parts = version.split('.');
  while (parts.length < 4) {
    parts.add('0');
  }
  return parts.join('.');
}
