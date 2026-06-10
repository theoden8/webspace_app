import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/trusted_hosts_service.dart';

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
  late List<TrustedHostEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _sorted(TrustedHostsService.instance.all());
  }

  List<TrustedHostEntry> _sorted(List<TrustedHostEntry> list) {
    list.sort((a, b) {
      final byHost = a.host.toLowerCase().compareTo(b.host.toLowerCase());
      if (byHost != 0) return byHost;
      return a.port.compareTo(b.port);
    });
    return list;
  }

  Future<void> _untrust(TrustedHostEntry entry) async {
    final loc = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.trustedCertRevokeDialogTitle),
        content: Text(
          loc.trustedCertRevokeDialogBody(entry.host, entry.port),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.trustedCertRevokeConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await TrustedHostsService.instance.untrust(
      host: entry.host,
      port: entry.port,
    );
    if (!mounted) return;
    setState(() {
      _entries = _sorted(TrustedHostsService.instance.all());
    });
  }

  Future<void> _confirmClearAll() async {
    final loc = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.trustedCertRevokeAllDialogTitle),
        content: Text(loc.trustedCertRevokeAllDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.trustedCertRevokeAllConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await TrustedHostsService.instance.clear();
    if (!mounted) return;
    setState(() {
      _entries = const [];
    });
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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.trustedCertScreenTitle),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: loc.trustedCertRevokeAllTooltip,
              icon: const Icon(Icons.delete_sweep),
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: _entries.isEmpty
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
              itemCount: _entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _entries[index];
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
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(loc.trustedCertCopied),
                              duration: const Duration(seconds: 2),
                            ),
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
