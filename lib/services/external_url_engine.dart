/// Parsed metadata for a non-webview URL (intent://, tel:, mailto:,
/// market:, custom app schemes, etc.). The rendering layer turns this
/// into a confirmation dialog and, on accept, hands it to url_launcher.
class ExternalUrlInfo {
  /// The original URL string as the webview saw it.
  final String url;

  /// Lowercase URI scheme (e.g. `intent`, `tel`, `mailto`, `market`).
  final String scheme;

  /// URI host when one is present. Intent URLs carry the target host
  /// here (e.g. `www.google.com` for Google Maps intents).
  final String? host;

  /// Android package extracted from intent:// extras (`;package=...`).
  /// Non-null only for intent URLs that name a target app.
  final String? package;

  /// `browser_fallback_url` extra from intent:// URLs — a regular web
  /// URL that should load in the webview when the target app is absent.
  final String? fallbackUrl;

  /// Target scheme embedded in intent:// extras (`;scheme=https`).
  /// Useful for reconstructing the intended web URL when no explicit
  /// fallback is provided.
  final String? targetScheme;

  const ExternalUrlInfo({
    required this.url,
    required this.scheme,
    this.host,
    this.package,
    this.fallbackUrl,
    this.targetScheme,
  });
}

/// Schemes handled by the webview itself — everything else is routed
/// through the external-URL confirmation flow.
const Set<String> _internalSchemes = {
  'http',
  'https',
  'data',
  'blob',
  'about',
  'file',
  'javascript',
  'view-source',
};

class ExternalUrlParser {
  /// Parses a URL the webview tried to navigate to. Returns null for
  /// normal webview navigations; a populated [ExternalUrlInfo] for
  /// intents and custom app schemes that must be routed to the OS.
  static ExternalUrlInfo? parse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme.isEmpty || _internalSchemes.contains(scheme)) return null;

    if (scheme == 'intent') {
      return _parseIntent(url, uri);
    }
    return ExternalUrlInfo(
      url: url,
      scheme: scheme,
      host: uri.host.isEmpty ? null : uri.host,
    );
  }

  /// Android intent:// URL format:
  ///   intent://HOST/PATH?QUERY#Intent;scheme=...;package=...;S.browser_fallback_url=...;end
  /// Extras live in the fragment, `;`-separated, with `S.` prefixing
  /// string extras per the Chrome intent scheme spec.
  static ExternalUrlInfo _parseIntent(String url, Uri uri) {
    String? package;
    String? fallbackUrl;
    String? targetScheme;

    final fragment = uri.fragment;
    if (fragment.startsWith('Intent;')) {
      final parts = fragment.substring('Intent;'.length).split(';');
      for (final part in parts) {
        if (part.isEmpty || part == 'end') continue;
        final eq = part.indexOf('=');
        if (eq < 0) continue;
        final key = part.substring(0, eq);
        final value = part.substring(eq + 1);
        switch (key) {
          case 'package':
            package = value;
            break;
          case 'scheme':
            targetScheme = value;
            break;
          case 'S.browser_fallback_url':
            try {
              fallbackUrl = Uri.decodeComponent(value);
            } catch (_) {
              fallbackUrl = value;
            }
            break;
        }
      }
    }

    return ExternalUrlInfo(
      url: url,
      scheme: 'intent',
      host: uri.host.isEmpty ? null : uri.host,
      package: package,
      fallbackUrl: fallbackUrl,
      targetScheme: targetScheme,
    );
  }
}
