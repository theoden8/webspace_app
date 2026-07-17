/// Parse a User-Agent string into a human-readable identity (browser +
/// version, OS + version) plus a list of validity issues, for display
/// under the UA field in site settings.
///
/// Pure Dart, UI-free: the screen maps [UaBrowser]/[UaOs] to icons and
/// [UaIssue] to localized copy. Parsing is token-sniffing in the same
/// precedence order servers use (specific markers before the Safari/Chrome
/// fallbacks that every WebKit/Blink UA carries).
library;

import 'package:webspace/services/user_agent_preset.dart';

enum UaBrowser {
  firefox,
  chrome,
  safari,
  edge,
  opera,
  samsungInternet,
  webview,
  unknown,
}

enum UaOs { windows, macos, linux, android, ios, unknown }

enum UaIssue {
  /// Does not follow the `Mozilla/5.0 (<platform>) ...` grammar every
  /// living browser emits.
  malformed,

  /// Gecko grammar with `rv:` and `Firefox/` disagreeing — a hand-edited
  /// string no real Firefox sends.
  geckoVersionMismatch,

  /// Carries an embedded-webview tell (stock default shape or the Android
  /// `; wv)` token); sites sniffing it may degrade or block logins.
  embeddedWebViewTell,

  /// Combines tokens no real browser ships together (e.g. an Apple mobile
  /// platform token inside the Gecko desktop grammar).
  impossibleHybrid,

  /// Firefox-shaped UA rendering a version older than the current known
  /// release.
  staleFirefoxVersion,
}

class UserAgentIdentity {
  final UaBrowser browser;
  final String? browserVersion;
  final UaOs os;
  final String? osVersion;
  final List<UaIssue> issues;

  const UserAgentIdentity({
    required this.browser,
    this.browserVersion,
    required this.os,
    this.osVersion,
    this.issues = const [],
  });
}

final RegExp _mozilla5Shape = RegExp(r'^Mozilla/5\.0 \([^)]+\) \S');
final RegExp _rvToken = RegExp(r'\brv:(\d+(?:\.\d+)*)\)');
final RegExp _firefoxToken = RegExp(r'\bFirefox/(\d+)(?:\.\d+)*');
final RegExp _fxiosToken = RegExp(r'\bFxiOS/(\d+)(?:\.\d+)*');
final RegExp _edgeToken = RegExp(r'\bEdgA?/(\d+)(?:\.\d+)*');
final RegExp _operaToken = RegExp(r'\b(?:OPR|Opera)[/ ](\d+)(?:\.\d+)*');
final RegExp _samsungToken = RegExp(r'\bSamsungBrowser/(\d+)(?:\.\d+)*');
final RegExp _chromeToken = RegExp(r'\bChrome/(\d+)(?:\.\d+)*');
final RegExp _crIosToken = RegExp(r'\bCriOS/(\d+)(?:\.\d+)*');
final RegExp _safariVersionToken = RegExp(r'\bVersion/(\d+(?:\.\d+)*)');
final RegExp _safariToken = RegExp(r'\bSafari/[\d.]+');
final RegExp _androidWvToken = RegExp(r'; wv\)');

final RegExp _windowsToken = RegExp(r'\bWindows NT (\d+(?:\.\d+)*)');
final RegExp _macToken = RegExp(r'\bMac OS X (\d+(?:[._]\d+)*)');
final RegExp _androidToken = RegExp(r'\bAndroid (\d+(?:\.\d+)*)');
final RegExp _iosToken =
    RegExp(r'\b(?:iPhone |iPad; CPU )?OS (\d+(?:_\d+)*) like Mac OS X');
final RegExp _appleMobileDevice = RegExp(r'\((?:iPhone|iPad|iPod)[;)]');
final RegExp _linuxToken = RegExp(r'\b(?:X11|Linux)\b');
final RegExp _geckoDesktopTrail = RegExp(r'\bGecko/20100101\b');

/// Describe [ua] for display. [currentFirefoxMajor] enables the
/// stale-version check on Firefox-shaped strings; pass null to skip it.
UserAgentIdentity describeUserAgent(String ua, {int? currentFirefoxMajor}) {
  final trimmed = ua.trim();
  if (trimmed.isEmpty) {
    return const UserAgentIdentity(browser: UaBrowser.unknown, os: UaOs.unknown);
  }

  final issues = <UaIssue>[];
  if (!_mozilla5Shape.hasMatch(trimmed)) issues.add(UaIssue.malformed);

  final os = _describeOs(trimmed);
  final browser = _describeBrowser(trimmed);

  final rv = _rvToken.firstMatch(trimmed);
  final firefox = _firefoxToken.firstMatch(trimmed);
  if (rv != null && firefox != null) {
    final rvFull = rv.group(1)!;
    if (!(RegExp(r'\bFirefox/' + RegExp.escape(rvFull) + r'\b')
        .hasMatch(trimmed))) {
      issues.add(UaIssue.geckoVersionMismatch);
    }
  }

  if (_appleMobileDevice.hasMatch(trimmed) &&
      _geckoDesktopTrail.hasMatch(trimmed)) {
    issues.add(UaIssue.impossibleHybrid);
  }

  if (browser.browser == UaBrowser.webview) {
    issues.add(UaIssue.embeddedWebViewTell);
  }

  final ffMajor = firefox != null
      ? int.tryParse(firefox.group(1)!)
      : (_fxiosToken.firstMatch(trimmed) != null
          ? int.tryParse(_fxiosToken.firstMatch(trimmed)!.group(1)!)
          : null);
  if (currentFirefoxMajor != null &&
      ffMajor != null &&
      ffMajor < currentFirefoxMajor) {
    issues.add(UaIssue.staleFirefoxVersion);
  }

  return UserAgentIdentity(
    browser: browser.browser,
    browserVersion: browser.version,
    os: os.os,
    osVersion: os.version,
    issues: issues,
  );
}

class _BrowserHit {
  final UaBrowser browser;
  final String? version;
  const _BrowserHit(this.browser, [this.version]);
}

_BrowserHit _describeBrowser(String ua) {
  if (isStockWebViewDefaultUserAgent(ua) || _androidWvToken.hasMatch(ua)) {
    return const _BrowserHit(UaBrowser.webview);
  }
  final fxios = _fxiosToken.firstMatch(ua);
  if (fxios != null) return _BrowserHit(UaBrowser.firefox, fxios.group(1));
  final edge = _edgeToken.firstMatch(ua);
  if (edge != null) return _BrowserHit(UaBrowser.edge, edge.group(1));
  final opera = _operaToken.firstMatch(ua);
  if (opera != null) return _BrowserHit(UaBrowser.opera, opera.group(1));
  final samsung = _samsungToken.firstMatch(ua);
  if (samsung != null) {
    return _BrowserHit(UaBrowser.samsungInternet, samsung.group(1));
  }
  final firefox = _firefoxToken.firstMatch(ua);
  if (firefox != null) return _BrowserHit(UaBrowser.firefox, firefox.group(1));
  final crios = _crIosToken.firstMatch(ua);
  if (crios != null) return _BrowserHit(UaBrowser.chrome, crios.group(1));
  final chrome = _chromeToken.firstMatch(ua);
  if (chrome != null) return _BrowserHit(UaBrowser.chrome, chrome.group(1));
  if (_safariToken.hasMatch(ua)) {
    final version = _safariVersionToken.firstMatch(ua)?.group(1);
    // A Safari/ tail without Version/ is the WebKit build number alone —
    // every WebKit UA carries it, so it identifies nothing by itself.
    return version != null
        ? _BrowserHit(UaBrowser.safari, version.split('.').first)
        : const _BrowserHit(UaBrowser.unknown);
  }
  return const _BrowserHit(UaBrowser.unknown);
}

class _OsHit {
  final UaOs os;
  final String? version;
  const _OsHit(this.os, [this.version]);
}

_OsHit _describeOs(String ua) {
  final ios = _iosToken.firstMatch(ua);
  if (ios != null || _appleMobileDevice.hasMatch(ua)) {
    return _OsHit(UaOs.ios, ios?.group(1)?.replaceAll('_', '.'));
  }
  final android = _androidToken.firstMatch(ua);
  if (android != null) return _OsHit(UaOs.android, android.group(1));
  final windows = _windowsToken.firstMatch(ua);
  if (windows != null) return _OsHit(UaOs.windows, windows.group(1));
  final mac = _macToken.firstMatch(ua);
  if (mac != null) {
    return _OsHit(UaOs.macos, mac.group(1)!.replaceAll('_', '.'));
  }
  if (_linuxToken.hasMatch(ua)) return const _OsHit(UaOs.linux);
  return const _OsHit(UaOs.unknown);
}
