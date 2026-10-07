import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/toast.dart';

/// Lists every (host, port, sha256) the user has approved via the
/// "Untrusted certificate" prompt. Each entry has an "Untrust" action
/// that removes the pin — the next visit to that host re-prompts.
///
/// The pin store is also consulted by `HttpClient.badCertificateCallback`
/// (favicon probes, downloads), so revoking here closes off non-webview
/// fetches too.
class TrustedCertificatesScreen extends StatefulWidget {
  const TrustedCertificatesScreen({super.key});

  @override
  State<TrustedCertificatesScreen> createState() =>
      _TrustedCertificatesScreenState();
}

class _TrustedCertificatesScreenState extends State<TrustedCertificatesScreen> {
  List<TrustedHostEntry> get _sortedEntries =>
      TrustedHostsService.instance.all()
        ..sort((a, b) {
          final byHost = a.host.toLowerCase().compareTo(b.host.toLowerCase());
          return byHost != 0 ? byHost : a.port.compareTo(b.port);
        });

  Future<void> _untrust(TrustedHostEntry entry) async {
    final loc = AppLocalizations.of(context);
    final ok = await confirm(
      context,
      title: loc.trustedCertRevokeDialogTitle,
      body: loc.trustedCertRevokeDialogBody(entry.host, entry.port),
      confirmLabel: loc.trustedCertRevokeConfirm,
      destructive: true,
    );
    if (!ok) return;
    await TrustedHostsService.instance.untrust(
      host: entry.host,
      port: entry.port,
    );
    if (mounted) setState(() {});
  }

  Future<void> _confirmClearAll() async {
    final loc = AppLocalizations.of(context);
    final ok = await confirm(
      context,
      title: loc.trustedCertRevokeAllDialogTitle,
      body: loc.trustedCertRevokeAllDialogBody,
      confirmLabel: loc.trustedCertRevokeAllConfirm,
      destructive: true,
    );
    if (!ok) return;
    await TrustedHostsService.instance.clear();
    if (mounted) setState(() {});
  }

  String _formatFingerprint(String sha256Hex) {
    final upper = sha256Hex.toUpperCase();
    return [
      for (var i = 0; i < upper.length; i += 2) upper.substring(i, i + 2),
    ].join(':');
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final entries = _sortedEntries;
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.trustedCertScreenTitle),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: loc.trustedCertRevokeAllTooltip,
              icon: const Icon(Icons.delete_sweep),
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      loc.trustedCertEmptyTitle,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      loc.trustedCertEmptyBody,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final formatted = _formatFingerprint(entry.sha256Hex);
                final hostPort = '${entry.host}:${entry.port}';
                return ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(hostPort),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          loc.trustedCertFingerprintLabel,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SelectableText(
                          formatted,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: loc.trustedCertCopyTooltip,
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: formatted));
                          ScaffoldMessenger.of(context).toast(
                            loc.trustedCertCopied,
                            duration: const Duration(seconds: 2),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: loc.trustedCertRevokeTooltip,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _untrust(entry),
                      ),
                    ],
                  ),
                  isThreeLine: true,
                );
              },
            ),
    );
  }
}
