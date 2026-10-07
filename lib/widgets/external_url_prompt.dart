import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart' show WebViewController;
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/widgets/toast.dart';

/// Shared per-route guard so rapid-fire redirects (Google Maps can hit the
/// webview with several intent:// bursts in a row) only surface one dialog.
final _confirming = ReentryGuard();

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
/// "Open in app" launches the intent URL. "Open in browser" loads the
/// cleaned `browser_fallback_url` inside our own webview — we are the
/// browser; handing the URL to a different one would lose per-site
/// settings and confuse the user. When [loadInWebView] is null (no
/// controller available), it falls back to launching the URL via the OS.
/// Tracking params are stripped from both via [ClearUrlService] before
/// they leave the app.
Future<void> confirmAndLaunchExternalUrl(
  BuildContext context,
  ExternalUrlInfo info, {
  WebViewController? loadInWebView,
}) async {
  // Loop guard: pages frequently re-fire the same intent immediately
  // after we load their browser_fallback_url. Without suppression the
  // user gets re-prompted every redirect and the choice they made a
  // moment ago is meaningless.
  if (ExternalUrlSuppressor.isSuppressedInfo(info)) {
    LogTag.externalUrl.debug(
        'suppressed (recently handled): ${info.url}', sensitive: true);
    return;
  }
  await _confirming.run(() async {
    final hasRules = ClearUrlService.instance.hasRules;
    final cleanedLaunchUrl = _stripTrackingFromIntent(info.url);
    final cleanedFallback = _cleanFallback(info.fallbackUrl);
    final urlChanged = cleanedLaunchUrl != info.url;
    final fallbackChanged = cleanedFallback != (info.fallbackUrl ?? '');
    LogTag.externalUrl.debug(
        'prompt: scheme=${info.scheme} package=${info.package} '
        'clearUrlsLoaded=$hasRules urlCleaned=$urlChanged '
        'fallbackCleaned=$fallbackChanged', sensitive: true);
    LogTag.externalUrl.debug('  rawUrl=${info.url}', sensitive: true);
    if (urlChanged) {
      LogTag.externalUrl.debug(
          '  cleanedUrl=$cleanedLaunchUrl', sensitive: true);
    }
    if (info.fallbackUrl != null) {
      LogTag.externalUrl.debug(
          '  rawFallback=${info.fallbackUrl}', sensitive: true);
      if (fallbackChanged) {
        LogTag.externalUrl.debug(
            '  cleanedFallback=$cleanedFallback', sensitive: true);
      }
    }

    // Only offer "Open in browser" for an http(s) fallback. The fallback is
    // attacker-influenced (extracted from the page's `intent://…` string), so
    // a `file://` / `javascript:` / `data:` value must never reach loadUrl —
    // it would disclose app-private files or run script in the document.
    final hasFallback = cleanedFallback.isNotEmpty &&
        ExternalUrlParser.isLoadableWebUrl(cleanedFallback);
    final loc = AppLocalizations.of(context);
    final packageName = info.package;
    final choice = await showDialog<_ExternalUrlChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.externalUrlPromptTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(loc.externalUrlPromptBody),
              const SizedBox(height: 8),
              SelectableText(
                cleanedLaunchUrl,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              if (packageName != null) ...[
                const SizedBox(height: 8),
                Text(loc.externalUrlPromptPackage(packageName)),
              ],
              if (hasFallback) ...[
                const SizedBox(height: 8),
                Text(loc.externalUrlPromptFallback(cleanedFallback)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ExternalUrlChoice.cancel),
            child: Text(loc.commonCancel),
          ),
          if (hasFallback)
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ExternalUrlChoice.openInBrowser),
              child: Text(loc.externalUrlPromptOpenInBrowser),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ExternalUrlChoice.openInApp),
            child: Text(loc.externalUrlPromptOpenInApp),
          ),
        ],
      ),
    );

    switch (choice ?? _ExternalUrlChoice.cancel) {
      case _ExternalUrlChoice.cancel:
        LogTag.externalUrl.debug('user chose: cancel');
        // Suppress so a script-driven redirect doesn't re-prompt the
        // user a second later for the choice they just declined.
        ExternalUrlSuppressor.mark(info);
        return;
      case _ExternalUrlChoice.openInBrowser:
        LogTag.externalUrl.debug(
            'user chose: open in browser → $cleanedFallback', sensitive: true);
        ExternalUrlSuppressor.mark(info);
        // We are the browser. Load the fallback inside our own webview
        // so per-site settings (cookie isolation, proxy, content blocker
        // etc.) still apply. shouldOverrideUrlLoading then decides
        // same-domain vs cross-domain (nested webview). When no
        // controller is available — e.g. tel:/mailto: with no fallback —
        // fall back to handing the URL to the OS.
        // Defense in depth: hasFallback already required an http(s)
        // fallback for this branch to be reachable, but re-check before
        // loading / launching so a future refactor can't reintroduce a
        // file:/javascript:/data: load here.
        if (!ExternalUrlParser.isLoadableWebUrl(cleanedFallback)) {
          LogTag.externalUrl.debug(
              'refused non-http(s) fallback', sensitive: true);
          return;
        }
        if (loadInWebView != null) {
          try {
            await loadInWebView.loadUrl(cleanedFallback);
          } catch (e) {
            LogTag.externalUrl.debug(
                'in-app loadUrl failed ($e), falling back to external launch',
                sensitive: true);
            await _launchExternally(cleanedFallback, label: 'browser fallback');
          }
        } else {
          await _launchExternally(cleanedFallback, label: 'browser');
        }
        return;
      case _ExternalUrlChoice.openInApp:
        LogTag.externalUrl.debug(
            'user chose: open in app → $cleanedLaunchUrl', sensitive: true);
        ExternalUrlSuppressor.mark(info);
        await _launchInApp(cleanedLaunchUrl, cleanedFallback, info.scheme);
        return;
    }
  });
}

/// Hands [url] to the system's default browser (or whichever app handles
/// http/https). Public entry for the per-site "open in browser" external
/// link mode (NESTED-009): an unclaimed cross-domain link tapped on such a
/// site leaves WebSpace entirely instead of opening a nested webview.
Future<bool> launchUrlInSystemBrowser(String url) =>
    _launchExternally(url, label: 'external-link');

/// Says that a link the user tapped was not followed because the site's
/// external links are blocked (NESTED-009). Not for script redirects: those
/// are the page's doing, and a page could flood the screen with them.
void showExternalLinkBlocked(String url) {
  final messengerContext = rootScaffoldMessengerKey.currentContext;
  final messenger = rootScaffoldMessengerKey.currentState;
  if (messengerContext == null || messenger == null) return;
  final host = Uri.tryParse(url)?.host ?? '';
  final target = host.isEmpty ? url : host;
  messenger.toast(
    AppLocalizations.of(messengerContext).externalLinkBlocked(target),
    duration: const Duration(seconds: 2),
    replace: true,
  );
}

/// Hands [url] to the OS via url_launcher so the system browser (or
/// whichever app handles the scheme) takes over. Used by both
/// "Open in browser" (with the cleaned http(s) fallback) and the
/// internal launch path inside [_launchInApp].
Future<bool> _launchExternally(String url, {required String label}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    LogTag.externalUrl.debug(
        '$label: invalid URL, cannot launch — $url', sensitive: true);
    return false;
  }
  try {
    final launched = await url_launcher.launchUrl(
      uri,
      mode: url_launcher.LaunchMode.externalApplication,
    );
    LogTag.externalUrl.debug(
        '$label: external launch result=$launched url=$url', sensitive: true);
    if (!launched) {
      final messengerContext = rootScaffoldMessengerKey.currentContext;
      final message = messengerContext != null
          ? AppLocalizations.of(messengerContext).externalUrlPromptNoAppAvailable(url)
          : 'No app available to open: $url';
      rootScaffoldMessengerKey.currentState?.toast(message);
    }
    return launched;
  } catch (e) {
    LogTag.externalUrl.debug(
        '$label: external launch threw — $e', sensitive: true);
    final messengerContext = rootScaffoldMessengerKey.currentContext;
    final message = messengerContext != null
        ? AppLocalizations.of(messengerContext).externalUrlPromptCouldNotOpen(url)
        : 'Could not open: $url';
    rootScaffoldMessengerKey.currentState?.toast(message);
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
    LogTag.externalUrl.debug('app launch failed, opening fallback externally');
    await _launchExternally(cleanedFallback, label: 'browser fallback after app failure');
  }
}
