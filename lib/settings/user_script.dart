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
