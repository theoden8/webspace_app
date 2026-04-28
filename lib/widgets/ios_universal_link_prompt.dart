import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:webspace/services/log_service.dart';
import 'package:webspace/widgets/root_messenger.dart';

/// Shared per-route guard so a redirect storm only surfaces one prompt.
bool _isPrompting = false;

/// User outcome for the iOS Universal Link prompt.
enum _UlChoice { cancel, continueHere, openInApp }

/// Confirmation dialog shown when an iOS WKWebView is about to be
/// auto-routed into a native app via apple-app-site-association
/// (Universal Links). Mirrors the Android `intent://` prompt:
///
///   * Cancel         — drop the navigation, stay where we were.
///   * Continue here  — load [url] in the webview via [continueHere];
///     bypasses Universal Link routing because programmatic loads
///     don't match against AASA.
///   * Open in app    — `url_launcher.launchUrl` external; iOS routes
///     it to the native app.
///
/// [continueHere] is supplied by the webview owner and typically
/// marks the URL as approved (so the reissued nav doesn't re-prompt)
/// and calls `controller.loadUrl(url)`.
Future<void> confirmIosUniversalLinkUrl(
  BuildContext context,
  String url, {
  required VoidCallback continueHere,
}) async {
  if (_isPrompting) return;
  _isPrompting = true;
  try {
    LogService.instance.log('IosUL', 'prompt: $url');
    final choice = await showDialog<_UlChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open external app?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('iOS would open this URL in the matching app:'),
              const SizedBox(height: 8),
              SelectableText(
                url,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _UlChoice.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _UlChoice.continueHere),
            child: const Text('Continue here'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _UlChoice.openInApp),
            child: const Text('Open in app'),
          ),
        ],
      ),
    );

    switch (choice ?? _UlChoice.cancel) {
      case _UlChoice.cancel:
        LogService.instance.log('IosUL', 'user chose: cancel');
        return;
      case _UlChoice.continueHere:
        LogService.instance.log('IosUL', 'user chose: continue here');
        continueHere();
        return;
      case _UlChoice.openInApp:
        LogService.instance.log('IosUL', 'user chose: open in app → $url');
        await _launchExternally(url);
        return;
    }
  } finally {
    _isPrompting = false;
  }
}

Future<void> _launchExternally(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    LogService.instance.log('IosUL', 'invalid URL, cannot launch — $url');
    return;
  }
  try {
    final launched = await url_launcher.launchUrl(
      uri,
      mode: url_launcher.LaunchMode.externalApplication,
    );
    LogService.instance.log('IosUL', 'external launch result=$launched url=$url');
    if (!launched) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('No app available to open: $url')),
      );
    }
  } catch (e) {
    LogService.instance.log('IosUL', 'external launch threw — $e');
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text('Could not open: $url')),
    );
  }
}
