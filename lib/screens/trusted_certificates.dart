import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke trust?'),
        content: Text(
          'The next visit to ${entry.host}:${entry.port} will prompt '
          'again before loading. Network requests outside the webview '
          '(favicons, downloads) for this host will also fail until '
          're-approved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke'),
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke all trust?'),
        content: const Text(
          'Every pinned certificate is removed. Self-signed sites you '
          'use will re-prompt on next visit.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke all'),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trusted certificates'),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: 'Revoke all',
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
                    const Text(
                      'No trusted certificates yet.',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'When you visit a site with a self-signed or '
                      'otherwise-untrusted certificate, you can choose '
                      '"Trust this site". The decision is stored here '
                      'and the prompt does not re-appear unless the '
                      'certificate changes.',
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
                return ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text('${entry.host}:${entry.port}'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SHA-256',
                          style: TextStyle(
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
                        tooltip: 'Copy fingerprint',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: formatted));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Fingerprint copied'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: 'Revoke',
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
