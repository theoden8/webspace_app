import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/host_storage.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A parsed ClearURLs provider that matches URLs and strips tracking parameters.
class ClearUrlProvider {
  final RegExp urlPattern;
  final bool completeProvider;
  final List<RegExp> rules;
  final List<RegExp> rawRules;
  final List<RegExp> exceptions;
  final List<RegExp> redirections;

  ClearUrlProvider({
    required this.urlPattern,
    this.completeProvider = false,
    this.rules = const [],
    this.rawRules = const [],
    this.exceptions = const [],
    this.redirections = const [],
  });
}

/// Singleton service for downloading, caching, parsing, and applying ClearURL rules.
/// Strips tracking parameters (utm_source, fbclid, etc.) from URLs using rules
/// maintained by the ClearURLs open-source project.
class ClearUrlService {
  static const String _rulesFileName = 'clearurl_rules.json';
  static const String _lastUpdatedKey = 'clearurl_last_updated';
  static const String _rulesUrl = 'https://rules2.clearurls.xyz/data.minify.json';

  static ClearUrlService? _instance;
  static ClearUrlService get instance => _instance ??= ClearUrlService._();

  ClearUrlService._();

  List<ClearUrlProvider> _providers = [];

  bool get hasRules => _providers.isNotEmpty;

  /// Initialize the service by loading cached rules from disk (no network).
  /// Call in main() at app startup.
  Future<void> initialize() async {
    try {
      final contents = await hostReadCacheText(_rulesFileName);
      if (contents == null) await _forgetPurgedDownload();
      if (contents != null) {
        final json = jsonDecode(contents);
        if (json is! Map<String, dynamic>) {
          throw const FormatException('the rules are not a JSON object');
        }
        _parseRules(json);
        LogTag.clearUrls.info(
            'Loaded ${_providers.length} providers from cache');
      }
    } on FormatException catch (e) {
      LogTag.clearUrls.error('Error loading cached rules: $e');
    } on IOException catch (e) {
      LogTag.clearUrls.error('Error loading cached rules: $e');
    }
  }

  /// Whether [initialize] found the rules downloaded but their file gone.
  bool _purged = false;

  /// The download is the file: a date with no file (the OS or the user
  /// cleared the cache, PLATFORM-010) is dropped, so the row offers the
  /// download, and [refetchPurged] fetches it again.
  Future<void> _forgetPurgedDownload() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_lastUpdatedKey)) return;
    LogTag.clearUrls.warning('The rules were downloaded but their file is '
        'gone; nothing is cleaned until they are fetched again');
    await prefs.remove(_lastUpdatedKey);
    _purged = true;
  }

  /// Downloads the rules again when the cache lost them, as the row's
  /// download button would (PLATFORM-010).
  Future<bool> refetchPurged() async {
    if (!_purged) return false;
    _purged = false;
    return downloadRules();
  }

  /// Download rules from the ClearURLs server, cache to disk, and parse.
  /// Returns true on success, false on failure.
  ///
  /// The download is routed through the app-global outbound proxy
  /// ([GlobalOutboundProxy.current]). When the configured proxy is
  /// malformed and cannot be honored, this returns false without making the
  /// request — falling back to direct would leak the device IP.
  Future<bool> downloadRules() async {
    final response = switch (
        await fetchViaAppProxy(Uri.parse(_rulesUrl), tag: LogTag.clearUrls)) {
      Fetched(:final response) => response,
      FetchRefused() || FetchFailed() => null,
    };
    if (response == null) return false;
    try {
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return false;
      await hostWriteCacheText(_rulesFileName, contents: response.body);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());
      _parseRules(json);
      LogTag.clearUrls.info(
          'Downloaded and parsed ${_providers.length} providers');
      return true;
    } on FormatException catch (e) {
      LogTag.clearUrls.error('Download error: $e');
      return false;
    } on IOException catch (e) {
      LogTag.clearUrls.error('Download error: $e');
      return false;
    } on PlatformException catch (e) {
      LogTag.clearUrls.error('Download error: $e');
      return false;
    }
  }

  /// Get the last time rules were downloaded, or null if never.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(_lastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
  }

  static final RegExp _urlRegExp = RegExp(r'^https?://', caseSensitive: false);

  /// Clean a URL by stripping tracking parameters according to loaded rules.
  /// Returns the cleaned URL, or the original if no changes were made.
  /// Returns an empty string if the URL should be blocked entirely (completeProvider).
  /// Returns the input unchanged if it is not a valid HTTP(S) URL.
  ///
  /// Idempotent (CURL-009): a redirector's target is cleaned too, so the
  /// navigation to the result does not come back with something left to
  /// strip.
  String cleanUrl(String url) => _clean(url, hops: 0);

  /// How many redirectors a URL may be wrapped in before it is returned as
  /// unwrapped so far.
  static const _maxRedirectHops = 4;

  String _clean(String url, {required int hops}) {
    if (_providers.isEmpty) return url;
    if (!_urlRegExp.hasMatch(url)) return url;

    for (final provider in _providers) {
      if (!provider.urlPattern.hasMatch(url)) continue;

      if (provider.exceptions.any((e) => e.hasMatch(url))) continue;

      if (provider.completeProvider) return '';

      for (final redirection in provider.redirections) {
        final match = redirection.firstMatch(url);
        if (match != null && match.groupCount >= 1) {
          final target = match.group(1);
          if (target != null && target.isNotEmpty) {
            final decoded = Uri.decodeComponent(target);
            // The capture group is whatever the matched page put in the
            // redirector's parameter, and callers navigate to what we return.
            // A `javascript:` / `data:` / `file:` target would run in, or
            // read from, the document doing the navigating.
            if (!ExternalUrlParser.isLoadableWebUrl(decoded)) break;
            return hops < _maxRedirectHops
                ? _clean(decoded, hops: hops + 1)
                : decoded;
          }
        }
      }

      var uri = Uri.tryParse(url);
      if (uri == null) continue;

      // Every value of a repeated key: `queryParameters` keeps one of them.
      if (uri.queryParametersAll.isNotEmpty) {
        final cleanedParams =
            Map<String, List<String>>.from(uri.queryParametersAll);
        cleanedParams.removeWhere((key, value) {
          return provider.rules.any((rule) => rule.hasMatch(key));
        });

        if (cleanedParams.length != uri.queryParametersAll.length) {
          if (cleanedParams.isEmpty) {
            uri = uri.replace(query: '');
            url = uri.toString();
            // Remove trailing '?' left by empty query
            if (url.endsWith('?')) {
              url = url.substring(0, url.length - 1);
            }
          } else {
            uri = uri.replace(queryParameters: cleanedParams);
            url = uri.toString();
          }
        }
      }

      for (final rawRule in provider.rawRules) {
        url = url.replaceAll(rawRule, '');
      }
    }

    return url;
  }

  /// Query keys present in [original] but gone from [cleaned], sorted and
  /// comma-joined for display in the protection report.
  ///
  /// Empty when the difference is not expressible as removed keys — a
  /// redirection rule swaps the whole URL, and naming the target's leftover
  /// parameters there would be a lie about what was stripped.
  static String strippedParamLabel(String original, {required String cleaned}) {
    if (cleaned.isEmpty || cleaned == original) return '';
    final from = Uri.tryParse(original);
    final to = Uri.tryParse(cleaned);
    if (from == null || to == null) return '';
    if (from.host != to.host || from.path != to.path) return '';
    final kept = to.queryParametersAll.keys.toSet();
    final removed = from.queryParametersAll.keys
        .where((key) => !kept.contains(key))
        .toList()
      ..sort();
    return removed.join(', ');
  }

  @visibleForTesting
  void loadRulesFromJson(Map<String, dynamic> json) {
    _parseRules(json);
  }

  /// No rules, as before [initialize]: a load always adds the built-ins.
  @visibleForTesting
  void resetForTest() {
    _providers = [];
    _purged = false;
  }

  void _parseRules(Map<String, dynamic> json) {
    final providers = <ClearUrlProvider>[];

    // Built-in providers for known cross-domain redirectors that the
    // upstream ClearURLs catalog misses or under-handles. Prepended
    // BEFORE the downloaded providers so they win the
    // first-match-wins iteration in [cleanUrl] — important because
    // the upstream catalog's per-host rules (e.g. for linkedin.com)
    // can strip parameters that those redirectors actually NEED in
    // order to honor the redirect (e.g. linkedin.com/safety/go
    // requires the `trk` parameter; without it the server replies
    // with a 404 page instead of the redirect target).
    //
    // Each redirector is handled via a `redirections` rule that
    // extracts the embedded destination URL directly, so we never
    // even request the redirector — we navigate to the destination
    // ourselves. That sidesteps the upstream parameter-stripping
    // issue entirely.
    providers.addAll(_builtInRedirectorProviders());

    final providersRaw = json['providers'];
    if (providersRaw == null || providersRaw is! Map) {
      _providers = providers;
      return;
    }
    final providersJson = Map<String, dynamic>.from(providersRaw);

    for (final MapEntry(:key, :value) in providersJson.entries) {
      if (value is! Map) continue;
      final urlPatternStr = value['urlPattern'];
      if (urlPatternStr is! String || urlPatternStr.isEmpty) continue;
      final RegExp urlPattern;
      try {
        urlPattern = RegExp(urlPatternStr, caseSensitive: false);
      } on FormatException catch (e) {
        LogTag.clearUrls.error('Error parsing provider "$key": $e');
        continue;
      }
      providers.add(ClearUrlProvider(
        urlPattern: urlPattern,
        completeProvider: value['completeProvider'] == true,
        rules: _parseRegexList(value['rules']),
        rawRules: _parseRegexList(value['rawRules']),
        exceptions: _parseRegexList(value['exceptions']),
        redirections: _parseRegexList(value['redirections']),
      ));
    }

    _providers = providers;
  }

  /// Built-in providers for cross-domain redirector URLs. Each one
  /// matches a known redirector pattern and extracts the embedded
  /// destination URL via `redirections`. ClearURLs upstream covers
  /// some of these but not all, and where it does cover them it
  /// sometimes only strips tracking parameters from the redirector
  /// URL itself rather than extracting the destination — which on
  /// `linkedin.com/safety/go` breaks the redirect because LinkedIn's
  /// server requires the `trk` parameter to honor the request.
  ///
  /// Adding these as built-ins (rather than pushing upstream) lets
  /// them ship without waiting for catalog updates.
  static List<ClearUrlProvider> _builtInRedirectorProviders() {
    return [
      // LinkedIn outbound-link redirector. Used in messaging,
      // articles, posts, notifications. Format:
      //   https://www.linkedin.com/safety/go?url=<encoded-target>&trk=...&...
      // ClearURLs upstream's linkedin provider strips `trk`, which
      // breaks safety/go's server-side redirect — we extract the
      // destination directly instead.
      ClearUrlProvider(
        urlPattern: RegExp(
          r'^https?://([\w-]+\.)*linkedin\.com/safety/go(\?|$)',
          caseSensitive: false,
        ),
        redirections: [
          RegExp(r'\?(?:.*&)?url=([^&#]+)', caseSensitive: false),
        ],
      ),
      // Google search outbound-link redirector. Format:
      //   https://www.google.com/url?q=<encoded-target>&sa=...
      // Also reachable as `google.<tld>/url` for regional Google.
      ClearUrlProvider(
        urlPattern: RegExp(
          r'^https?://([\w-]+\.)*google\.[a-z.]+/url(\?|$)',
          caseSensitive: false,
        ),
        redirections: [
          RegExp(r'\?(?:.*&)?q=([^&#]+)', caseSensitive: false),
        ],
      ),
      // DuckDuckGo search outbound-link redirector. Format:
      //   https://duckduckgo.com/l/?uddg=<encoded-target>&...
      ClearUrlProvider(
        urlPattern: RegExp(
          r'^https?://([\w-]+\.)*duckduckgo\.com/l/?(\?|$)',
          caseSensitive: false,
        ),
        redirections: [
          RegExp(r'\?(?:.*&)?uddg=([^&#]+)', caseSensitive: false),
        ],
      ),
    ];
  }

  List<RegExp> _parseRegexList(Object? list) {
    if (list is! List) return [];
    final result = <RegExp>[];
    for (final item in list) {
      if (item is String && item.isNotEmpty) {
        try {
          result.add(RegExp(item, caseSensitive: false));
        } on FormatException catch (e) {
          LogTag.clearUrls.error('Invalid regex "$item": $e');
        }
      }
    }
    return result;
  }

}
