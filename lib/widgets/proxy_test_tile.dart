import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';

/// "Test connection" for a proxy configuration, plus the answer (PROXY-019).
///
/// [settings] is a callback, not a value: the test runs against what is in
/// the form right now, including edits the user has not saved yet. Testing
/// the persisted copy would answer a question nobody asked.
class ProxyTestTile extends StatefulWidget {
  const ProxyTestTile({
    super.key,
    required this.settings,
    required this.target,
    this.siteId,
  });

  final UserProxySettings Function() settings;

  /// Where the probe request goes. See [proxyTestTarget].
  final Uri target;

  /// Tor stream-isolation tag, so a per-site test rides the site's circuit.
  final String? siteId;

  @override
  State<ProxyTestTile> createState() => _ProxyTestTileState();
}

class _ProxyTestTileState extends State<ProxyTestTile> {
  bool _running = false;
  ProxyTestResult? _result;

  Future<void> _run() async {
    // The button disables itself while a test is in flight, but a second tap
    // can land before that frame is painted.
    if (_running) return;
    setState(() {
      _running = true;
      _result = null;
    });
    final settings = widget.settings();
    try {
      final result = await testProxyConnection(
        settings,
        target: widget.target,
        siteId: widget.siteId,
      );
      logProxyTest(settings, result);
      if (mounted) setState(() => _result = result);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  ({IconData icon, Color color, String message}) _describe(
    AppLocalizations loc,
    ColorScheme scheme,
    ProxyTestResult result,
  ) {
    switch (result.outcome) {
      case ProxyTestOutcome.reachable:
        // The padlock green: it is the app's one "this is fine" colour and
        // it clears 3:1 on both light and dark surfaces.
        return (
          icon: Icons.check_circle_outline,
          color: SecurityIndicator.secure,
          message: loc.proxyTestOk,
        );
      case ProxyTestOutcome.authRejected:
        return (
          icon: Icons.lock_outline,
          color: scheme.error,
          message: loc.proxyTestAuthRejected,
        );
      case ProxyTestOutcome.unreachable:
      case ProxyTestOutcome.timedOut:
      case ProxyTestOutcome.blocked:
        return (
          icon: Icons.error_outline,
          color: scheme.error,
          message: loc.proxyTestUnreachable,
        );
    }
  }

  /// The data half of the answer: which host was reached and with what
  /// status, or the error that came back instead.
  String? _detailOf(ProxyTestResult result) {
    if (result.statusCode != null) {
      return 'HTTP ${result.statusCode} - ${widget.target.host}';
    }
    return result.detail;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final result = _result;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Spacing.lg, Spacing.xs, Spacing.lg, Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wrap, not Row: at 2x text the button's own label is wider than a
          // 320pt phone, and the hint and spinner have to drop to the next
          // line rather than overflow it.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              OutlinedButton.icon(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.network_check, size: IconSizes.action),
                label: Text(loc.proxyTestRun),
              ),
              HintButton(
                title: loc.proxyTestRun,
                description: loc.proxyTestHint,
              ),
              if (_running)
                const SizedBox(
                  width: IconSizes.action,
                  height: IconSizes.action,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (result != null) ...[
            const SizedBox(height: Spacing.sm),
            Builder(builder: (context) {
              final d = _describe(loc, theme.colorScheme, result);
              final detail = _detailOf(result);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(d.icon, size: IconSizes.action, color: d.color),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.message,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: d.color),
                        ),
                        // Verbatim, untranslated: a status line, or the
                        // underlying error. Paraphrasing the latter is what
                        // makes a proxy problem unreportable.
                        if (detail != null)
                          Text(
                            detail,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }
}
