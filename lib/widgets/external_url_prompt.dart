import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/widgets/root_messenger.dart';

/// Shared per-route guard so rapid-fire redirects (Google Maps can hit the
/// webview with several intent:// bursts in a row) only surface one dialog.
bool _isConfirming = false;

/// Strips ClearURLs tracking query params from a URL, regardless of scheme,
/// by reconstructing it as an https URL (which the ClearURLs ruleset
/// recognizes), running [ClearUrlService.cleanUrl], then putting the
/// cleaned query back. Returns the input on any parse failure or when no
/// rules are loaded.
String _stripTrackingFromQuery(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (uri.query.isEmpty) return url;
  if (!ClearUrlService.instance.hasRules) return url;

  final asHttps = 'https://${uri.host}${uri.path}?${uri.query}';
  final cleaned = ClearUrlService.instance.cleanUrl(asHttps);
  if (cleaned == asHttps || cleaned.isEmpty) return url;
  final cleanedUri = Uri.tryParse(cleaned);
  if (cleanedUri == null) return url;
  return uri.replace(query: cleanedUri.hasQuery ? cleanedUri.query : null).toString();
}

/// Strips ClearURLs from an intent:// URL: cleans the toplevel query AND
/// the URL-encoded `S.browser_fallback_url` extra inside the fragment.
/// Without the fragment-rewrite step, `utm_campaign` survives the
/// embedded fallback URL even though it gets stripped from the toplevel.
String _stripTrackingFromIntent(String intentUrl) {
  final uri = Uri.tryParse(intentUrl);
  if (uri == null) return intentUrl;
  if (uri.scheme.toLowerCase() != 'intent') return intentUrl;
  if (!ClearUrlService.instance.hasRules) return intentUrl;

  // Step 1: clean the toplevel query.
  String cleaned = _stripTrackingFromQuery(intentUrl);

  // Step 2: clean the embedded browser_fallback_url inside the Intent
  // extras. Re-parse because step 1 may have changed the URL.
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
    } catch (_) {
      continue;
    }
    final cleanedFallback = ClearUrlService.instance.cleanUrl(decoded);
    if (cleanedFallback == decoded || cleanedFallback.isEmpty) continue;
    parts[i] = 'S.browser_fallback_url=${Uri.encodeComponent(cleanedFallback)}';
    rewroteAny = true;
  }
  if (!rewroteAny) return cleaned;
  final newFragment = 'Intent;${parts.join(';')}';
  return cleanedUri.replace(fragment: newFragment).toString();
}

String _cleanFallback(String? fallbackUrl) {
  if (fallbackUrl == null || fallbackUrl.isEmpty) return '';
  if (!ClearUrlService.instance.hasRules) return fallbackUrl;
  final cleaned = ClearUrlService.instance.cleanUrl(fallbackUrl);
  return cleaned.isEmpty ? fallbackUrl : cleaned;
}

/// Outcome of the confirmation dialog.
enum _ExternalUrlChoice { cancel, openInApp, openInBrowser }

/// Ask the user whether to hand [info.url] to the OS via url_launcher.
/// "Open in app" launches the intent URL. "Open in browser" launches
/// the cleaned `browser_fallback_url` externally so the user's default
/// browser handles it. Tracking params are stripped from both via
/// [ClearUrlService] before they leave the app.
Future<void> confirmAndLaunchExternalUrl(
  BuildContext context,
  ExternalUrlInfo info,
) async {
  // Loop guard: pages frequently re-fire the same intent immediately
  // after we load their browser_fallback_url. Without suppression the
  // user gets re-prompted every redirect and the choice they made a
  // moment ago is meaningless.
  if (ExternalUrlSuppressor.isSuppressedInfo(info)) {
    LogService.instance.log(
      'ExternalUrl',
      'suppressed (recently handled): ${info.url}',
    );
    return;
  }
  if (_isConfirming) return;
  _isConfirming = true;
  try {
    final hasRules = ClearUrlService.instance.hasRules;
    final cleanedLaunchUrl = _stripTrackingFromIntent(info.url);
    final cleanedFallback = _cleanFallback(info.fallbackUrl);
    final urlChanged = cleanedLaunchUrl != info.url;
    final fallbackChanged = cleanedFallback != (info.fallbackUrl ?? '');
    LogService.instance.log(
      'ExternalUrl',
      'prompt: scheme=${info.scheme} package=${info.package} '
      'clearUrlsLoaded=$hasRules urlCleaned=$urlChanged '
      'fallbackCleaned=$fallbackChanged',
    );
    LogService.instance.log('ExternalUrl', '  rawUrl=${info.url}');
    if (urlChanged) {
      LogService.instance.log('ExternalUrl', '  cleanedUrl=$cleanedLaunchUrl');
    }
    if (info.fallbackUrl != null) {
      LogService.instance.log('ExternalUrl', '  rawFallback=${info.fallbackUrl}');
      if (fallbackChanged) {
        LogService.instance.log('ExternalUrl', '  cleanedFallback=$cleanedFallback');
      }
    }

    final hasFallback = cleanedFallback.isNotEmpty;
    final choice = await showDialog<_ExternalUrlChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open external app?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('This site wants to open:'),
              const SizedBox(height: 8),
              SelectableText(
                cleanedLaunchUrl,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              if (info.package != null) ...[
                const SizedBox(height: 8),
                Text('Package: ${info.package}'),
              ],
              if (hasFallback) ...[
                const SizedBox(height: 8),
                Text('Fallback URL: $cleanedFallback'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ExternalUrlChoice.cancel),
            child: const Text('Cancel'),
          ),
          if (hasFallback)
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ExternalUrlChoice.openInBrowser),
              child: const Text('Open in browser'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ExternalUrlChoice.openInApp),
            child: const Text('Open in app'),
          ),
        ],
      ),
    );

    switch (choice ?? _ExternalUrlChoice.cancel) {
      case _ExternalUrlChoice.cancel:
        LogService.instance.log('ExternalUrl', 'user chose: cancel');
        // Suppress so a script-driven redirect doesn't re-prompt the
        // user a second later for the choice they just declined.
        ExternalUrlSuppressor.mark(info);
        return;
      case _ExternalUrlChoice.openInBrowser:
        LogService.instance.log('ExternalUrl', 'user chose: open in browser → $cleanedFallback');
        ExternalUrlSuppressor.mark(info);
        // Hand the URL to the OS so the user's default browser opens
        // it. Loading inside our webview was the previous behavior;
        // for hostile sites (Google Maps mobile is the canonical
        // example) the page just JS-redirects right back to intent://
        // and we end up at about:blank. The external browser is what
        // "Open in browser" means in every other app's mental model.
        await _launchExternally(cleanedFallback, label: 'browser');
        return;
      case _ExternalUrlChoice.openInApp:
        LogService.instance.log('ExternalUrl', 'user chose: open in app → $cleanedLaunchUrl');
        ExternalUrlSuppressor.mark(info);
        await _launchInApp(cleanedLaunchUrl, cleanedFallback, info.scheme);
        return;
    }
  } finally {
    _isConfirming = false;
  }
}

/// Hands [url] to the OS via url_launcher so the system browser (or
/// whichever app handles the scheme) takes over. Used by both
/// "Open in browser" (with the cleaned http(s) fallback) and the
/// internal launch path inside [_launchInApp].
Future<bool> _launchExternally(String url, {required String label}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    LogService.instance.log('ExternalUrl', '$label: invalid URL, cannot launch — $url');
    return false;
  }
  try {
    final launched = await url_launcher.launchUrl(
      uri,
      mode: url_launcher.LaunchMode.externalApplication,
    );
    LogService.instance.log('ExternalUrl', '$label: external launch result=$launched url=$url');
    if (!launched) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('No app available to open: $url')),
      );
    }
    return launched;
  } catch (e) {
    LogService.instance.log('ExternalUrl', '$label: external launch threw — $e');
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text('Could not open: $url')),
    );
    return false;
  }
}

Future<void> _launchInApp(
  String launchUrl,
  String cleanedFallback,
  String scheme,
) async {
  final launched = await _launchExternally(launchUrl, label: 'app');
  if (launched) return;
  // No app handler — fall back to opening the cleaned http(s) URL in
  // the user's default browser, same as if they'd picked
  // "Open in browser". For sites without a browser_fallback_url
  // (tel:, custom schemes, etc.) _launchExternally already showed a
  // "no app available" snackbar.
  if (cleanedFallback.isNotEmpty) {
    LogService.instance.log('ExternalUrl', 'app launch failed, opening fallback externally');
    await _launchExternally(cleanedFallback, label: 'browser fallback after app failure');
  }
}
