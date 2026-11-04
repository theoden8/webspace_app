import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/network_sign_in.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/confirm_dialog.dart';

/// Shows the "untrusted certificate" confirmation dialog. Returns `true`
/// if the user opts to proceed; the caller is responsible for persisting
/// the trust decision via [TrustedHostsService] (the webview wiring in
/// [WebViewFactory] does this automatically when the platform surfaced
/// the cert's DER bytes). One dialog per certificate at a time is
/// `WebViewTls`'s to keep (TLS-013).
///
/// The same dialog is reused by every code path that builds a
/// [WebViewConfig], so a self-signed-cert prompt looks identical whether
/// the user is on a top-level site, an `InAppBrowser` nested screen, or
/// any future webview surface.
Future<bool> promptUntrustedCertificate(
  BuildContext context, {
  required String host,
  required int port,
  required inapp.SslCertificate? certificate,
}) async {
  if (!context.mounted) return false;
  final loc = AppLocalizations.of(context);
  final fingerprint =
      TrustedHostsService.fingerprintFromInappCertificate(certificate);
  final issuedTo = certificate?.issuedTo?.CName?.trim();
  final issuedBy = certificate?.issuedBy?.CName?.trim();
  final notAfter = certificate?.validNotAfterDate;
  return await confirm(
    context,
    title: loc.untrustedCertTitle,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(loc.untrustedCertBody(host, port)),
        const SizedBox(height: 8),
        Text(loc.untrustedCertWarning),
        const SizedBox(height: 12),
        if (issuedTo != null && issuedTo.isNotEmpty)
          _CertField(label: loc.untrustedCertIssuedTo, value: issuedTo),
        if (issuedBy != null && issuedBy.isNotEmpty)
          _CertField(label: loc.untrustedCertIssuedBy, value: issuedBy),
        if (notAfter != null)
          _CertField(
            label: loc.untrustedCertExpires,
            value: notAfter.toIso8601String().split('T').first,
          ),
        if (fingerprint != null)
          _CertField(
            label: loc.untrustedCertSha256,
            value: _formatFingerprint(fingerprint),
          ),
      ],
    ),
    confirmLabel: loc.untrustedCertTrustConfirm,
    destructive: false,
  );
}

/// Tells the user the network holds traffic back for its sign-in page, which
/// answered [notice]'s host in the site's place (TLS-012), and opens the OS's
/// Wi-Fi settings where it has them.
Future<void> showNetworkSignIn(
  BuildContext context, {
  required SignInNotice notice,
}) async {
  if (!context.mounted) return;
  final loc = AppLocalizations.of(context);
  final answeredAs = notice.answeredAs;
  final content = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(loc.networkSignInBody(notice.host)),
      if (answeredAs != null && answeredAs.isNotEmpty) ...[
        const SizedBox(height: Spacing.md),
        _CertField(label: loc.untrustedCertIssuedTo, value: answeredAs),
      ],
    ],
  );
  if (!NetworkSignIn.canOpenSignIn) {
    await choose<bool>(
      context,
      title: loc.networkSignInTitle,
      content: content,
      options: [(true, loc.commonOk)],
    );
    return;
  }
  final open = await confirm(
    context,
    title: loc.networkSignInTitle,
    content: content,
    confirmLabel: loc.networkSignInOpenSettings,
    destructive: false,
    cancelLabel: loc.commonClose,
  );
  if (open) await NetworkSignIn.openSignIn();
}

class _CertField extends StatelessWidget {
  final String label;
  final String value;
  const _CertField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }
}

String _formatFingerprint(String sha256Hex) {
  final upper = sha256Hex.toUpperCase();
  return [
    for (var i = 0; i < upper.length; i += 2) upper.substring(i, i + 2),
  ].join(':');
}
