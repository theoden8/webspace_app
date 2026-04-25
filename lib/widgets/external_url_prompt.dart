import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/widgets/root_messenger.dart';

/// Shared per-route guard so rapid-fire redirects (Google Maps can hit the
/// webview with several intent:// bursts in a row) only surface one dialog.
bool _isConfirming = false;

/// Strips ClearURLs tracking query params from an `intent://` URL by
/// reconstructing it as an https URL (which the ClearURLs ruleset
/// recognizes), running [ClearUrlService.cleanUrl], then putting the
/// cleaned query back. Falls back to the input on any parse failure.
/// Non-intent URLs are returned unchanged.
String _stripTrackingFromIntent(String intentUrl) {
  final uri = Uri.tryParse(intentUrl);
  if (uri == null) return intentUrl;
  if (uri.scheme.toLowerCase() != 'intent') return intentUrl;
  if (uri.query.isEmpty) return intentUrl;
  if (!ClearUrlService.instance.hasRules) return intentUrl;

  final asHttps = 'https://${uri.host}${uri.path}?${uri.query}';
  final cleaned = ClearUrlService.instance.cleanUrl(asHttps);
  if (cleaned == asHttps || cleaned.isEmpty) return intentUrl;
  final cleanedUri = Uri.tryParse(cleaned);
  if (cleanedUri == null) return intentUrl;
  return uri.replace(query: cleanedUri.hasQuery ? cleanedUri.query : null).toString();
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
/// If the OS has no handler (or the user declines) and the intent carried
/// a `browser_fallback_url`, load that in [fallbackController] instead.
/// Tracking parameters are stripped from both the launched intent URL and
/// the fallback URL via [ClearUrlService] before they leave the app.
Future<void> confirmAndLaunchExternalUrl(
  BuildContext context,
  ExternalUrlInfo info, {
  WebViewController? fallbackController,
}) async {
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

    final hasFallback = cleanedFallback.isNotEmpty && fallbackController != null;
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
        return;
      case _ExternalUrlChoice.openInBrowser:
        LogService.instance.log('ExternalUrl', 'user chose: open in browser → $cleanedFallback');
        await fallbackController!.loadUrl(cleanedFallback);
        return;
      case _ExternalUrlChoice.openInApp:
        LogService.instance.log('ExternalUrl', 'user chose: open in app → $cleanedLaunchUrl');
        await _launchInApp(cleanedLaunchUrl, cleanedFallback, fallbackController, info.scheme);
        return;
    }
  } finally {
    _isConfirming = false;
  }
}

Future<void> _launchInApp(
  String launchUrl,
  String cleanedFallback,
  WebViewController? fallbackController,
  String scheme,
) async {
  final uri = Uri.tryParse(launchUrl);
  var launched = false;
  if (uri != null) {
    try {
      launched = await url_launcher.launchUrl(
        uri,
        mode: url_launcher.LaunchMode.externalApplication,
      );
    } catch (e) {
      LogService.instance.log('ExternalUrl', 'launchUrl threw: $e');
      launched = false;
    }
  }
  LogService.instance.log('ExternalUrl', 'launched=$launched url=$launchUrl');
  // Note: on Android, launchUrl can return true even when no app handles
  // the intent (the OS shows its own "no app" toast). We can't distinguish
  // that from a real launch — that's why the dialog offers an explicit
  // "Open in browser" button rather than relying on this fallback.
  if (launched) return;

  if (cleanedFallback.isNotEmpty && fallbackController != null) {
    LogService.instance.log('ExternalUrl', 'launch failed, loading fallback: $cleanedFallback');
    await fallbackController.loadUrl(cleanedFallback);
    return;
  }
  rootScaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(content: Text('No app available to open $scheme:')),
  );
}
