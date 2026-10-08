import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show SslCertificate;
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/widgets/http_auth_prompt.dart';
import 'package:webspace/widgets/toast.dart';
import 'package:webspace/widgets/untrusted_cert_prompt.dart';

/// What a site webview asks the user, as dialogs over the page that owns
/// [context]: the same questions for a site's own webview and for the nested
/// screens it opens.
class DialogWebViewPrompts implements MediaPrompter {
  const DialogWebViewPrompts(this.context);

  final BuildContext context;

  /// Shows a popup window for handling window.open() requests from webviews.
  /// Used for Cloudflare Turnstile challenges and other popup-based flows.
  Future<void> showPopup(int windowId, {required String url}) async {
    if (!context.mounted) return;

    LogTag.popupWindow.debug(
        'Opening popup window with id: $windowId, url: $url', sensitive: true);

    final loc = AppLocalizations.of(context);
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding: EdgeInsets.all(16),
          child: Container(
            width: MediaQuery.of(dialogContext).size.width * 0.9,
            height: MediaQuery.of(dialogContext).size.height * 0.8,
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(loc.homeVerificationTitle, style: TextStyle(fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PopupWebView.createPopupWebView(
                    windowId: windowId,
                    onCloseWindow: () {
                      if (Navigator.of(dialogContext).canPop()) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    LogTag.popupWindow.debug('Popup window closed');
  }

  /// Stable callback for the untrusted-TLS-certificate prompt. Used by
  /// both parent and nested webviews so a self-signed site looks the
  /// same regardless of where it was opened. Persistence (and pinning to
  /// the cert's SHA-256) happens inside [WebViewFactory] when this
  /// returns true — the dialog itself only collects user intent.
  Future<bool> untrustedCertificate(
    String host, {
    required int port,
    required inapp.SslCertificate? certificate,
  }) {
    if (!context.mounted) return Future.value(false);
    return promptUntrustedCertificate(
      context,
      host: host,
      port: port,
      certificate: certificate,
    );
  }

  /// Stable callback for the HTTP authentication sign-in prompt, shared by
  /// parent and nested webviews (HTTPAUTH-003).
  Future<HttpAuthPromptResult?> httpAuth(HttpAuthPromptRequest request) {
    if (!context.mounted) return Future.value(null);
    return promptHttpAuth(context, request: request);
  }

  /// Stable callback for the user-script fetch-from-URL confirmation prompt.
  /// Used by both the parent webview (via `getWebView`) and the nested
  /// `InAppWebViewScreen` so external dependency loading prompts the user
  /// the same way regardless of where the webview was opened.
  Future<bool> confirmScriptFetch(String url) async {
    if (!context.mounted) return false;
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeLoadExternalScriptTitle),
        content: Text(loc.homeLoadExternalScriptBody(url)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.homeDenyAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.homeAllowAction),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Shown the first time a site requests `PROTECTED_MEDIA_ID` (e.g. the
  /// Spotify web player). The [GrantStore] remembers the answer, so this only
  /// collects user intent.
  @override
  Future<bool> protectedContent(String origin) async {
    if (!context.mounted) return false;
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homePlayProtectedContentTitle),
        content: Text(loc.homePlayProtectedContentBody(origin)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.homeBlockAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.homeAllowAction),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// The first request shows Block / Use a file / Allow (no Allow for a kind
  /// with no real mode); picking the file opens a picker and the chosen media
  /// becomes the site's virtual source. The [GrantStore] remembers the answer,
  /// so this only collects user intent. A site already set to `virtual` but
  /// missing a file skips the popup for the picker. A dismissed popup returns
  /// `ask`, so the request is denied once and the popup returns next time; a
  /// cancelled picker leaves the prior mode for the same reason. Android's
  /// app-level camera permission is handled at grant time by
  /// `CameraPermissionService`.
  @override
  Future<CaptureGrant> capture(
    CaptureKind kind, {
    required String origin,
    required CaptureMode current,
  }) async {
    if (!context.mounted) return (mode: kind.block, source: null);
    if (current == kind.virtual) {
      return _pickVirtualOrKeep(kind, fallback: current);
    }
    final loc = AppLocalizations.of(context);
    final text = kind.text(loc);
    final real = kind.real;
    final choice = await showDialog<_MediaChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(text.promptTitle),
        content: Text(text.promptBody(origin)),
        actions: [
          for (final choice in _MediaChoice.values)
            if (choice != _MediaChoice.allow || real != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, choice),
                child: Text(switch (choice) {
                  _MediaChoice.block => loc.homeBlockAction,
                  _MediaChoice.useFile => text.useFile,
                  _MediaChoice.allow => loc.homeAllowAction,
                }),
              ),
        ],
      ),
    );
    return switch (choice) {
      _MediaChoice.allow => (mode: real ?? kind.block, source: null),
      _MediaChoice.useFile =>
        await _pickVirtualOrKeep(kind, fallback: kind.ask),
      _MediaChoice.block => (mode: kind.block, source: null),
      null => (mode: kind.ask, source: null),
    };
  }

  /// Runs the picker. On success returns `virtual` with the source; on cancel
  /// or error returns [fallback] with no source, so the stored mode survives
  /// and the request is denied this once.
  Future<CaptureGrant> _pickVirtualOrKeep(
    CaptureKind kind, {
    required CaptureMode fallback,
  }) async {
    final result = await VirtualMediaPicker.pick(kind.medium);
    if (result.source case final source?) {
      return (mode: kind.virtual, source: source);
    }
    if (result.error case final error? when context.mounted) {
      ScaffoldMessenger.of(context)
          .toast(kind.text(AppLocalizations.of(context)).pickError(error));
    }
    return (mode: fallback, source: null);
  }
}

enum _MediaChoice { block, useFile, allow }
