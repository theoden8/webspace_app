import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/trusted_hosts_service.dart';

/// Re-entrancy guard: a single TLS challenge can fire repeatedly while
/// the dialog is still on screen (e.g. parallel sub-resources). Without
/// this, a user with a self-signed site would see a stack of identical
/// "trust this cert?" dialogs.
final Set<String> _pendingPrompts = <String>{};

/// Shows the "untrusted certificate" confirmation dialog. Returns `true`
/// if the user opts to proceed; the caller is responsible for persisting
/// the trust decision via [TrustedHostsService] (the webview wiring in
/// [WebViewFactory] does this automatically when the platform surfaced
/// the cert's DER bytes).
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
  final key = '$host:$port';
  if (_pendingPrompts.contains(key)) return false;
  _pendingPrompts.add(key);
  try {
    if (!context.mounted) return false;
    final loc = AppLocalizations.of(context);
    final fingerprint =
        TrustedHostsService.fingerprintFromInappCertificate(certificate);
    final issuedTo = certificate?.issuedTo?.CName?.trim();
    final issuedBy = certificate?.issuedBy?.CName?.trim();
    final notAfter = certificate?.validNotAfterDate;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.untrustedCertTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                loc.untrustedCertBody(host, port),
              ),
              const SizedBox(height: 8),
              Text(
                loc.untrustedCertWarning,
              ),
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
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.untrustedCertTrustConfirm),
          ),
        ],
      ),
    );
    return approved ?? false;
  } finally {
    _pendingPrompts.remove(key);
  }
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
  final buf = StringBuffer();
  for (var i = 0; i < upper.length; i += 2) {
    if (i > 0) buf.write(':');
    buf.write(upper.substring(i, i + 2));
  }
  return buf.toString();
}
