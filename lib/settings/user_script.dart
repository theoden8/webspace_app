/// Model for a user-defined script to inject into webviews.
///
/// Each script has a name, source code, injection time, and enabled toggle.
/// Optionally, a [url] can be set to fetch script source from a CDN.
/// The fetched content is cached in [urlSource]. At injection time the
/// full script is [urlSource] + [source], so users can load a library
/// from URL and call its API in [source].
///
/// Scripts are stored per-site in WebViewModel and serialized to JSON.
enum UserScriptInjectionTime {
  atDocumentStart,
  atDocumentEnd,
}

/// Trusted CDN domains for user script external dependencies.
/// URLs matching these domains are fetched without user confirmation.
/// Other http/https URLs prompt the user before fetching.
const Set<String> scriptFetchWhitelist = {
  // General-purpose CDNs
  'cdn.jsdelivr.net',
  'unpkg.com',
  'cdnjs.cloudflare.com',
  'cdn.cloudflare.com',
  // GitHub / GitLab raw content
  'raw.githubusercontent.com',
  'gist.githubusercontent.com',
  'gitlab.com',
  // Google hosted libraries
  'ajax.googleapis.com',
  // Microsoft / jQuery
  'ajax.aspnetcdn.com',
  'code.jquery.com',
  // Specific popular libraries
  'cdn.skypack.dev',
  'esm.sh',
  'ga.jspm.io',
};

/// Result of validating a URL for script fetching.
enum ScriptFetchUrlStatus {
  /// URL is on the trusted whitelist — fetch without confirmation.
  whitelisted,
  /// URL is valid http/https but not whitelisted — requires user confirmation.
  requiresConfirmation,
  /// URL scheme is blocked (javascript:, data:, blob:, file://) or invalid.
  blocked,
}

/// Validate a URL for script fetching and classify it.
///
/// Returns [ScriptFetchUrlStatus.whitelisted] for trusted CDN domains,
/// [ScriptFetchUrlStatus.requiresConfirmation] for other http/https URLs,
/// and [ScriptFetchUrlStatus.blocked] for dangerous or invalid URLs.
ScriptFetchUrlStatus classifyScriptFetchUrl(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return ScriptFetchUrlStatus.blocked;
  }

  final scheme = uri.scheme.toLowerCase();

  // Only allow http and https
  if (scheme != 'http' && scheme != 'https') {
    return ScriptFetchUrlStatus.blocked;
  }

  final host = uri.host.toLowerCase();
  if (host.isEmpty) return ScriptFetchUrlStatus.blocked;

  // Check whitelist: exact match or subdomain match
  for (final domain in scriptFetchWhitelist) {
    if (host == domain || host.endsWith('.$domain')) {
      return ScriptFetchUrlStatus.whitelisted;
    }
  }

  return ScriptFetchUrlStatus.requiresConfirmation;
}

class UserScriptConfig {
  String name;
  String source;
  /// Optional URL to fetch script source from (e.g., CDN-hosted library).
  /// Fetched at the Dart level, bypassing page CSP restrictions.
  String? url;
  /// Cached content downloaded from [url].
  String? urlSource;
  UserScriptInjectionTime injectionTime;
  bool enabled;

  UserScriptConfig({
    required this.name,
    required this.source,
    this.url,
    this.urlSource,
    this.injectionTime = UserScriptInjectionTime.atDocumentEnd,
    this.enabled = true,
  });

  /// The full script to inject: URL source (if any) followed by user source.
  String get fullSource {
    if (urlSource != null && urlSource!.isNotEmpty) {
      if (source.isNotEmpty) {
        return '$urlSource\n$source';
      }
      return urlSource!;
    }
    return source;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'source': source,
        if (url != null) 'url': url,
        if (urlSource != null) 'urlSource': urlSource,
        'injectionTime': injectionTime.index,
        'enabled': enabled,
      };

  factory UserScriptConfig.fromJson(Map<String, dynamic> json) {
    return UserScriptConfig(
      name: json['name'] ?? 'Untitled',
      source: json['source'] ?? '',
      url: json['url'],
      urlSource: json['urlSource'],
      injectionTime: json['injectionTime'] == 0
          ? UserScriptInjectionTime.atDocumentStart
          : UserScriptInjectionTime.atDocumentEnd,
      enabled: json['enabled'] ?? true,
    );
  }
}
