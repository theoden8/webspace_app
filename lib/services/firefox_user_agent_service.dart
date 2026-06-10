import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';

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
  try {
    final json = jsonDecode(body);
    if (json is Map && json['LATEST_FIREFOX_VERSION'] is String) {
      return parseFirefoxVersionDisplay(json['LATEST_FIREFOX_VERSION'] as String);
    }
  } catch (_) {}
  return null;
}

/// Tracks the current Firefox release version by scraping it from Firefox
/// source at runtime, so generated per-site User-Agents stay current without
/// an app release. Falls back to [kDefaultFirefoxMajorVersion] baked into the
/// build when offline or the scrape fails. The scraped version only ever
/// moves forward (never below the bundled floor).
class FirefoxUserAgentService {
  static const String _versionKey = 'firefox_ua_major_version';
  static const String _lastCheckedKey = 'firefox_ua_last_checked';

  /// How long a successful or failed check is trusted before re-scraping.
  /// Firefox ships ~monthly; a weekly check keeps us current without
  /// hammering the network on every cold start.
  static const Duration _refreshTtl = Duration(days: 7);

  /// Canonical "source code" location: the release branch's user-facing
  /// version file in mozilla-release.
  static const String _sourceVersionUrl =
      'https://hg.mozilla.org/releases/mozilla-release/raw-file/tip/'
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
  Future<bool>? _inFlight;

  /// Current Firefox major version (scraped, or the bundled floor).
  int get majorVersion => _major;

  /// Current Firefox version rendered for a UA string, e.g. `"151.0"`.
  String get versionString => firefoxVersionString(_major);

  String get linuxDesktopUserAgent =>
      buildFirefoxUserAgent(kFirefoxLinuxPlatformToken, versionString);
  String get macosDesktopUserAgent =>
      buildFirefoxUserAgent(kFirefoxMacosPlatformToken, versionString);
  String get windowsDesktopUserAgent =>
      buildFirefoxUserAgent(kFirefoxWindowsPlatformToken, versionString);

  /// OS descriptor tokens the randomize button cycles through (desktop +
  /// mobile), matching the historical `generateRandomUserAgent` set.
  static const List<String> randomPlatformTokens = [
    kFirefoxWindowsPlatformToken,
    kFirefoxMacosPlatformToken,
    'Linux x86_64',
    'iPhone; CPU iPhone OS 15_7_3 like Mac OS X',
    'Android 16; Mobile',
  ];

  /// A Firefox UA for a randomly chosen platform at the current version.
  /// Inject [rng] to make the choice deterministic in tests.
  String randomUserAgent([Random? rng]) {
    final r = rng ?? Random();
    final token = randomPlatformTokens[r.nextInt(randomPlatformTokens.length)];
    return buildFirefoxUserAgent(token, versionString);
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
      LogService.instance
          .log('FirefoxUA', 'init error: $e', level: LogLevel.error);
    }
  }

  /// Scrape only if the last check is older than [_refreshTtl]. Safe to
  /// fire-and-forget from startup.
  Future<bool> refreshIfStale() async {
    final last = _lastChecked;
    if (last != null && DateTime.now().difference(last) < _refreshTtl) {
      return false;
    }
    return refresh();
  }

  /// Scrape the current Firefox version now and persist it. Concurrent calls
  /// share one in-flight request. Returns true when a newer version was
  /// adopted.
  Future<bool> refresh() => _inFlight ??= _refresh().whenComplete(() {
        _inFlight = null;
      });

  Future<bool> _refresh() async {
    final scraped = await _scrapeMajorVersion();
    // Record the check time even on failure so we honor the TTL when offline
    // rather than re-scraping on every navigation/startup.
    _lastChecked = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastCheckedKey, _lastChecked!.toIso8601String());
      if (scraped != null && scraped > _major) {
        _major = scraped;
        await prefs.setInt(_versionKey, _major);
        LogService.instance.log(
            'FirefoxUA', 'Firefox version updated to $_major',
            level: LogLevel.info);
        return true;
      }
    } catch (e) {
      LogService.instance
          .log('FirefoxUA', 'persist error: $e', level: LogLevel.error);
    }
    return false;
  }

  Future<int?> _scrapeMajorVersion() async {
    final clientResult = outboundHttp.clientFor(GlobalOutboundProxy.current);
    if (clientResult is OutboundClientBlocked) {
      LogService.instance.log('FirefoxUA', 'Skipped: ${clientResult.reason}',
          level: LogLevel.warning);
      return null;
    }
    final client = (clientResult as OutboundClientReady).client;
    try {
      return await _fetchVersion(
              client, _sourceVersionUrl, parseFirefoxVersionDisplay) ??
          await _fetchVersion(
              client, _productDetailsUrl, parseFirefoxProductDetails);
    } finally {
      client.close();
    }
  }

  /// Reset in-memory state to the bundled default. Tests only — the singleton
  /// otherwise carries a monotonically advanced version across cases.
  @visibleForTesting
  void resetForTest() {
    _major = kDefaultFirefoxMajorVersion;
    _lastChecked = null;
    _inFlight = null;
  }

  Future<int?> _fetchVersion(
      http.Client client, String url, int? Function(String) parse) async {
    try {
      final resp =
          await client.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        LogService.instance.log('FirefoxUA', 'HTTP ${resp.statusCode} from $url',
            level: LogLevel.warning);
        return null;
      }
      return parse(resp.body);
    } catch (e) {
      LogService.instance
          .log('FirefoxUA', 'fetch $url failed: $e', level: LogLevel.warning);
      return null;
    }
  }
}
