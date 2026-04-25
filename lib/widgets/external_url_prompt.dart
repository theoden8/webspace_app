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
    final cleanedLaunchUrl = _stripTrackingFromIntent(info.url);
    final cleanedFallback = _cleanFallback(info.fallbackUrl);
    LogService.instance.log(
      'ExternalUrl',
      'prompt: scheme=${info.scheme} package=${info.package} '
      'rawUrl=${info.url} cleanedUrl=$cleanedLaunchUrl '
      'rawFallback=${info.fallbackUrl} cleanedFallback=$cleanedFallback',
    );

    final confirmed = await showDialog<bool>(
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
              if (cleanedFallback.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Fallback URL: $cleanedFallback'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      LogService.instance.log('ExternalUrl', 'user declined: $cleanedLaunchUrl');
      // Even though shouldOverrideUrlLoading returned CANCEL and we called
      // stopLoading() in the webview, Android sometimes paints an
      // ERR_UNKNOWN_URL_SCHEME error page when the navigation was a
      // server-side redirect. Loading the cleaned fallback URL keeps the
      // user on a usable page; otherwise leave them where they were.
      if (cleanedFallback.isNotEmpty && fallbackController != null) {
        await fallbackController.loadUrl(cleanedFallback);
      }
      return;
    }

    final uri = Uri.tryParse(cleanedLaunchUrl);
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
    LogService.instance.log('ExternalUrl', 'launched=$launched url=$cleanedLaunchUrl');
    if (launched) return;

    if (cleanedFallback.isNotEmpty && fallbackController != null) {
      LogService.instance.log('ExternalUrl', 'loading fallback in webview: $cleanedFallback');
      await fallbackController.loadUrl(cleanedFallback);
      return;
    }
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text('No app available to open ${info.scheme}:')),
    );
  } finally {
    _isConfirming = false;
  }
}
