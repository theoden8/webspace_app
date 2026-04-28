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
/// through the external-URL confirmation flow. The chrome-* family is
/// rendered by the Chromium engine that powers Android's WebView (e.g.
/// `chrome://version`, `chrome-error://chromewebdata` from a failed
/// load); they aren't OS app launches and shouldn't prompt.
const Set<String> _internalSchemes = {
  'http',
  'https',
  'data',
  'blob',
  'about',
  'file',
  'javascript',
  'view-source',
  'chrome',
  'chrome-extension',
  'chrome-error',
  'chrome-search',
  'chrome-untrusted',
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

/// Loop-suppression for external URL prompts. After the user decides what
/// to do with an intent (open in app / browser / cancel), pages commonly
/// re-fire the same intent moments later (Google Maps does this every
/// visit). The suppression list breaks that loop and lets the
/// `onReceivedError` recovery in `webview.dart` skip reloading a URL the
/// user already chose to leave alone.
class ExternalUrlSuppressor {
  ExternalUrlSuppressor._();

  static final Map<String, DateTime> _suppressed = {};

  static String _keyForInfo(ExternalUrlInfo info) {
    final uri = Uri.tryParse(info.url);
    final hostPath = uri == null ? info.url : '${uri.host}${uri.path}';
    return '${info.scheme}|$hostPath|${info.package ?? ''}';
  }

  /// Returns true if a suppression entry exists for [info] and hasn't
  /// expired.
  static bool isSuppressedInfo(ExternalUrlInfo info) =>
      _checkExpiry(_keyForInfo(info));

  /// URL-keyed variant — convenience for callers that only have the raw
  /// URL string (e.g. `onReceivedError` in webview.dart).
  static bool isSuppressedUrl(String url) {
    final info = ExternalUrlParser.parse(url);
    return info == null ? false : isSuppressedInfo(info);
  }

  static void mark(
    ExternalUrlInfo info, {
    Duration duration = const Duration(seconds: 30),
  }) {
    _suppressed[_keyForInfo(info)] = DateTime.now().add(duration);
  }

  static bool _checkExpiry(String key) {
    final expiry = _suppressed[key];
    if (expiry == null) return false;
    if (DateTime.now().isAfter(expiry)) {
      _suppressed.remove(key);
      return false;
    }
    return true;
  }

  /// Test hook.
  static void clear() => _suppressed.clear();
}
