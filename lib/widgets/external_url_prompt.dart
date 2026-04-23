import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/widgets/root_messenger.dart';

/// Shared per-route guard so rapid-fire redirects (Google Maps can hit the
/// webview with several intent:// bursts in a row) only surface one dialog.
bool _isConfirming = false;

/// Ask the user whether to hand [info.url] to the OS via url_launcher.
/// If the OS has no handler (or the user declines) and the intent carried
/// a `browser_fallback_url`, load that in [fallbackController] instead.
Future<void> confirmAndLaunchExternalUrl(
  BuildContext context,
  ExternalUrlInfo info, {
  WebViewController? fallbackController,
}) async {
  if (_isConfirming) return;
  _isConfirming = true;
  try {
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
                info.url,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              if (info.package != null) ...[
                const SizedBox(height: 8),
                Text('Package: ${info.package}'),
              ],
              if (info.fallbackUrl != null) ...[
                const SizedBox(height: 8),
                Text('Fallback URL: ${info.fallbackUrl}'),
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
    if (confirmed != true) return;

    final uri = Uri.tryParse(info.url);
    var launched = false;
    if (uri != null) {
      try {
        launched = await url_launcher.launchUrl(
          uri,
          mode: url_launcher.LaunchMode.externalApplication,
        );
      } catch (_) {
        launched = false;
      }
    }
    if (launched) return;

    final fallback = info.fallbackUrl;
    if (fallback != null && fallback.isNotEmpty && fallbackController != null) {
      await fallbackController.loadUrl(fallback);
      return;
    }
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text('No app available to open ${info.scheme}:')),
    );
  } finally {
    _isConfirming = false;
  }
}
