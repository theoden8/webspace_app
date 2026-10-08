import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/utils/concurrency.dart';

/// Upper bound on a plausible scraped Firefox major version. An HTML error
/// page or a redirected mirror can yield a stray integer; anything past this
/// is treated as garbage rather than poisoning the cached UA version.
const int _kMaxPlausibleFirefoxMajor = 999;

/// Parse a Firefox major version from a `version_display.txt` body. The file
/// holds the user-facing release string, e.g. `"151.0"`, `"151.0.1"`,
/// `"140.3.0esr"`, `"153.0a1"` — we only need the leading integer (the UA
/// freezes the minor at `.0`). Returns null when no leading integer is found
/// or it is outside the plausible range.
int? parseFirefoxVersionDisplay(String body) {
  final m = RegExp(r'^\s*(\d+)').firstMatch(body);
  if (m == null) return null;
  final v = int.tryParse(m.group(1)!);
  if (v == null || v <= 0 || v > _kMaxPlausibleFirefoxMajor) return null;
  return v;
}

/// Parse `LATEST_FIREFOX_VERSION` out of Mozilla's product-details JSON
/// (`firefox_versions.json`). Used as the fallback source when the raw
/// source file is unreachable.
int? parseFirefoxProductDetails(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return null;
  }
  final version = json is Map ? json['LATEST_FIREFOX_VERSION'] : null;
  return version is String ? parseFirefoxVersionDisplay(version) : null;
}

/// Outcome of a user-initiated [FirefoxUserAgentService.refresh].
enum FirefoxVersionRefreshResult {
  /// A newer version was scraped and adopted.
  updated,

  /// The scrape succeeded but the version was already current.
  unchanged,

  /// The scrape failed (offline, both sources unreachable, or garbage body).
  failed,
}

/// Tracks the current Firefox release version by scraping it from Firefox
/// source. The scrape is performed on explicit user action (a button in app
/// settings), or at startup when the user has opted in to automatic updates
/// ([AppPref.firefoxUaAutoRefresh], default off, throttled to weekly) — so the
/// app makes no network request the user did not ask for (an F-Droid
/// inclusion requirement). Until an update runs, generated per-site
/// User-Agents render at [kDefaultFirefoxMajorVersion] baked into the build.
/// The cached version only ever moves forward (never below the bundled
/// floor).
class FirefoxUserAgentService {
  static const String _versionKey = 'firefox_ua_major_version';
  static const String _lastCheckedKey = 'firefox_ua_last_checked';

  /// Canonical "source code" location: the release branch's user-facing
  /// version file. Firefox development moved from hg.mozilla.org to GitHub
  /// (mozilla-firefox/firefox) in 2025; the old
  /// `hg.mozilla.org/releases/mozilla-release/raw-file/tip/...` URL now
  /// returns "not found in manifest".
  static const String _sourceVersionUrl =
      'https://raw.githubusercontent.com/mozilla-firefox/firefox/release/'
      'browser/config/version_display.txt';

  /// Official machine-readable fallback maintained by Mozilla.
  static const String _productDetailsUrl =
      'https://product-details.mozilla.org/1.0/firefox_versions.json';

  static FirefoxUserAgentService? _instance;
  static FirefoxUserAgentService get instance =>
      _instance ??= FirefoxUserAgentService._();
  FirefoxUserAgentService._();

  int _major = kDefaultFirefoxMajorVersion;
  DateTime? _lastChecked;
  SingleFlight<(), FirefoxVersionRefreshResult> _refreshes = SingleFlight();

  /// Current Firefox major version (scraped, or the bundled floor).
  int get majorVersion => _major;

  /// When the version was last successfully checked against Firefox source,
  /// or null if the user has never run an update on this device.
  DateTime? get lastChecked => _lastChecked;

  /// Current Firefox version rendered for a UA string, e.g. `"151.0"`.
  String get versionString => firefoxVersionString(_major);

  String get linuxDesktopUserAgent =>
      buildFirefoxUserAgent(kFirefoxLinuxPlatformToken, version: versionString);
  String get macosDesktopUserAgent =>
      buildFirefoxUserAgent(kFirefoxMacosPlatformToken, version: versionString);
  String get windowsDesktopUserAgent =>
      buildFirefoxUserAgent(kFirefoxWindowsPlatformToken,
          version: versionString);

  /// The full set of Firefox UAs the randomize button cycles through —
  /// desktop (Linux/macOS/Windows) plus realistic Firefox-for-Android and
  /// Firefox-for-iOS shapes — all rendered at the current version. Exposed so
  /// a future "pick platform" UI can offer the same set.
  List<String> get randomUserAgents => [
        linuxDesktopUserAgent,
        macosDesktopUserAgent,
        windowsDesktopUserAgent,
        buildFirefoxAndroidUserAgent(versionString),
        buildFirefoxIosUserAgent(versionString),
      ];

  /// A randomly chosen UA from [randomUserAgents] at the current version.
  /// Inject [rng] to make the choice deterministic in tests.
  String randomUserAgent([Random? rng]) {
    final pool = randomUserAgents;
    return pool[(rng ?? Random()).nextInt(pool.length)];
  }

  /// Load the cached version from disk (no network). Call at app startup.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getInt(_versionKey) ?? 0;
      _major = max(kDefaultFirefoxMajorVersion, cached);
      final ts = prefs.getString(_lastCheckedKey);
      if (ts != null) _lastChecked = DateTime.tryParse(ts);
    } catch (e) {
      LogTag.firefoxUa.error('init error: $e');
    }
  }

  /// Scrape the current Firefox version now and persist it. MUST be called
  /// only from an explicit user gesture or from [maybeAutoRefresh] under the
  /// user's opt-in — this is the single network seam of this service.
  /// Concurrent calls share one in-flight request.
  Future<FirefoxVersionRefreshResult> refresh() =>
      _refreshes.run((), call: _refresh);

  /// Minimum spacing between automatic refreshes. Manual refreshes are
  /// never throttled.
  static const Duration kAutoRefreshInterval = Duration(days: 7);

  /// Startup hook for the opt-in automatic update: refreshes only when the
  /// user has enabled [AppPref.firefoxUaAutoRefresh] and the last successful
  /// check is older than [kAutoRefreshInterval] (or has never happened).
  /// No-ops otherwise, so the default behavior stays "no network unless
  /// asked". Call after [initialize]; never awaited on the startup path.
  Future<void> maybeAutoRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    if (!AppPref.firefoxUaAutoRefresh.load(prefs)) return;
    final last = _lastChecked;
    if (last != null && DateTime.now().difference(last) < kAutoRefreshInterval) {
      return;
    }
    await refresh();
  }

  Future<FirefoxVersionRefreshResult> _refresh() async {
    final scraped = await _scrapeMajorVersion();
    if (scraped == null) return FirefoxVersionRefreshResult.failed;

    final isNewer = scraped > _major;
    if (isNewer) _major = scraped;
    _lastChecked = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (isNewer) await prefs.setInt(_versionKey, _major);
      await prefs.setString(_lastCheckedKey, _lastChecked!.toIso8601String());
    } catch (e) {
      LogTag.firefoxUa.error('persist error: $e');
    }
    if (isNewer) {
      LogTag.firefoxUa.info('Firefox version updated to $_major');
      return FirefoxVersionRefreshResult.updated;
    }
    return FirefoxVersionRefreshResult.unchanged;
  }

  Future<int?> _scrapeMajorVersion() async {
    for (final (url, parse) in [
      (_sourceVersionUrl, parseFirefoxVersionDisplay),
      (_productDetailsUrl, parseFirefoxProductDetails),
    ]) {
      switch (await fetchViaAppProxy(Uri.parse(url), tag: LogTag.firefoxUa)) {
        case FetchRefused():
          return null;
        case FetchFailed():
          continue;
        case Fetched(:final response):
          final major = parse(response.body);
          if (major != null) return major;
      }
    }
    return null;
  }

  /// Reset in-memory state to the bundled default. Tests only — the singleton
  /// otherwise carries a monotonically advanced version across cases.
  @visibleForTesting
  void resetForTest() {
    _major = kDefaultFirefoxMajorVersion;
    _lastChecked = null;
    _refreshes = SingleFlight();
  }
}
