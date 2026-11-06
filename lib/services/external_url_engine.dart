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
      return _parseIntent(url, uri: uri);
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
  static ExternalUrlInfo _parseIntent(String url, {required Uri uri}) {
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
            } on ArgumentError {
              // How the SDK reports a malformed %-escape.
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

  /// Schemes iOS registers to Safari for "force open in Safari" links.
  /// Sites use them to escape embedded webviews (x.com redirects every
  /// in-app-browser visit to `x-safari-https://redirect.x.com/...`).
  /// The wrapped URL is the original with the scheme prefixed, so
  /// stripping the prefix recovers a loadable http(s) URL.
  static const _safariSchemePrefix = 'x-safari-';
  static const _safariSchemes = {'x-safari-http', 'x-safari-https'};

  /// Resolves any external-scheme URL to an equivalent http(s) URL the
  /// webview can load, or null when none exists and the confirmation
  /// dialog should be shown instead. Covers `intent://` (via
  /// [intentToWebUrl]) and the Safari force-open `x-safari-http(s)`
  /// family.
  static String? toWebUrl(ExternalUrlInfo info) {
    if (info.scheme == 'intent') return intentToWebUrl(info);
    if (_safariSchemes.contains(info.scheme)) {
      final sep = info.url.indexOf('://');
      if (sep < 0) return null;
      final target = info.scheme.substring(_safariSchemePrefix.length);
      final candidate = '$target${info.url.substring(sep)}';
      final parsed = Uri.tryParse(candidate);
      if (parsed == null || parsed.host.isEmpty) return null;
      return candidate;
    }
    return null;
  }

  /// Whether [url] is a plain http(s) URL safe to hand to `loadUrl` or an
  /// external "open in browser" launch. The intent `browser_fallback_url`
  /// is attacker-influenced (a page hands us the whole `intent://…` string),
  /// so before *loading* a fallback we must re-check its scheme — a
  /// `file://` / `javascript:` / `data:` fallback would otherwise disclose
  /// app-private files or run script in the current document. [toWebUrl]
  /// already enforces this on the silent route; call sites that load a
  /// fallback from the confirmation dialog MUST gate on this too.
  static bool isLoadableWebUrl(String url) {
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  /// Resolves an [ExternalUrlInfo] for an intent:// URL to an equivalent
  /// http(s) URL the webview can load: prefers the explicit
  /// `S.browser_fallback_url` extra; otherwise reconstructs from
  /// `targetScheme` + the intent's host/path/query when the target scheme
  /// is http(s). Returns null when no equivalent web URL can be produced
  /// (e.g. zxing scanner intent with no fallback).
  static String? intentToWebUrl(ExternalUrlInfo info) {
    if (info.scheme != 'intent') return null;
    final fallback = info.fallbackUrl;
    if (fallback != null && fallback.isNotEmpty) {
      final parsed = Uri.tryParse(fallback);
      if (parsed != null && (parsed.scheme == 'http' || parsed.scheme == 'https')) {
        return fallback;
      }
    }
    final scheme = info.targetScheme;
    if (scheme != 'http' && scheme != 'https') return null;
    final original = Uri.tryParse(info.url);
    if (original == null || original.host.isEmpty) return null;
    return Uri(
      scheme: scheme,
      host: original.host,
      port: original.hasPort ? original.port : null,
      path: original.path,
      query: original.query.isEmpty ? null : original.query,
    ).toString();
  }
}

/// What the prompt shows and hands on for an external URL: the URL itself
/// and the fallback it resolved to, each with its tracking parameters
/// stripped (EXT-006); the fallback is empty when there is none.
typedef CleanedExternalUrl = ({String launch, String fallback});

/// [info] with [clean] (ClearURLs; null when no rules are loaded) run over
/// an intent's own query, the `S.browser_fallback_url` it carries in its
/// extras, and the fallback the parser resolved: a parameter stripped from
/// one and left in another would still leave the app (EXT-006).
CleanedExternalUrl cleanExternalUrl(
  ExternalUrlInfo info, {
  required String Function(String url)? clean,
}) {
  final fallback = info.fallbackUrl ?? '';
  if (clean == null) return (launch: info.url, fallback: fallback);
  final cleanedFallback = fallback.isEmpty ? '' : clean(fallback);
  return (
    launch: _stripTrackingFromIntent(info.url, clean: clean),
    fallback: cleanedFallback.isEmpty ? fallback : cleanedFallback,
  );
}

/// [url]'s query run through [clean], whatever its scheme: the query is put
/// on an https URL of the same host and path, which the ClearURLs rules
/// recognize, and the cleaned query put back. [url] as it is when it does
/// not parse or nothing is stripped.
String _stripTrackingFromQuery(
  String url, {
  required String Function(String url) clean,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.query.isEmpty) return url;
  final asHttps = 'https://${uri.host}${uri.path}?${uri.query}';
  final cleaned = clean(asHttps);
  if (cleaned == asHttps || cleaned.isEmpty) return url;
  final cleanedUri = Uri.tryParse(cleaned);
  if (cleanedUri == null) return url;
  return uri
      .replace(query: cleanedUri.hasQuery ? cleanedUri.query : null)
      .toString();
}

/// An intent:// URL with [clean] run over its toplevel query and the
/// URL-encoded `S.browser_fallback_url` extra inside its fragment; any
/// other URL as it is. Without the fragment rewrite, `utm_campaign`
/// survives the embedded fallback even though it goes from the toplevel.
String _stripTrackingFromIntent(
  String intentUrl, {
  required String Function(String url) clean,
}) {
  final uri = Uri.tryParse(intentUrl);
  if (uri == null || uri.scheme.toLowerCase() != 'intent') return intentUrl;
  final cleaned = _stripTrackingFromQuery(intentUrl, clean: clean);
  // Re-parsed: the query's rewrite may have moved the fragment.
  final cleanedUri = Uri.tryParse(cleaned);
  if (cleanedUri == null) return cleaned;
  final fragment = cleanedUri.fragment;
  if (!fragment.startsWith('Intent;')) return cleaned;
  final parts = fragment.substring('Intent;'.length).split(';');
  var rewroteAny = false;
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (!part.startsWith('S.browser_fallback_url=')) continue;
    final rawValue = part.substring('S.browser_fallback_url='.length);
    String decoded;
    try {
      decoded = Uri.decodeComponent(rawValue);
    } on ArgumentError {
      // A truncated or invalid %-escape.
      continue;
    } on FormatException {
      // Escapes that decode to no UTF-8.
      continue;
    }
    final cleanedFallback = clean(decoded);
    if (cleanedFallback == decoded || cleanedFallback.isEmpty) continue;
    parts[i] = 'S.browser_fallback_url=${Uri.encodeComponent(cleanedFallback)}';
    rewroteAny = true;
  }
  if (!rewroteAny) return cleaned;
  return cleanedUri.replace(fragment: 'Intent;${parts.join(';')}').toString();
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
}
