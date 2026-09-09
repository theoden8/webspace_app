// The one place a user can read what the embedded Tor client is doing.
//
// Before this existed the feature was unreadable: a site set to TOR either
// showed a mute progress bar or a mute error icon, and the only text
// anywhere was a single log line that fired on a blocked fetch. A privacy
// feature the user cannot verify is barely a feature, so the card reports
// the state, the bootstrap phase, the live SOCKS endpoint, and — when it
// fails — which kind of failure it is and what to do about it (TOR-013,
// TOR-015).
//
// Gated with the rest of Tor on `TorService.isAvailable`, which is the
// platform gate AND developer mode (DEVTOOLS-010).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/tor_bridge_settings.dart';
import 'package:webspace/services/tor_bridges.dart' show bridgesMayHelp;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';

/// User-facing heading and remedy for a failure kind.
///
/// Shared by the card and the in-webview interstitial so the two cannot
/// drift into describing the same failure differently. Every kind is
/// covered explicitly — the switch is exhaustive over the enum, so a new
/// kind fails to compile rather than silently rendering as "unknown".
({String title, String body}) torFailureCopy(
  AppLocalizations loc,
  TorFailureKind kind,
) {
  return switch (kind) {
    TorFailureKind.offline =>
      (title: loc.torFailOfflineTitle, body: loc.torFailOfflineBody),
    TorFailureKind.censored =>
      (title: loc.torFailCensoredTitle, body: loc.torFailCensoredBody),
    TorFailureKind.clockSkew =>
      (title: loc.torFailClockSkewTitle, body: loc.torFailClockSkewBody),
    TorFailureKind.exitPolicy =>
      (title: loc.torFailExitPolicyTitle, body: loc.torFailExitPolicyBody),
    TorFailureKind.controlChannel => (
        title: loc.torFailControlChannelTitle,
        body: loc.torFailControlChannelBody
      ),
    TorFailureKind.bootstrapTimeout =>
      (title: loc.torFailTimeoutTitle, body: loc.torFailTimeoutBody),
    TorFailureKind.runtime =>
      (title: loc.torFailRuntimeTitle, body: loc.torFailRuntimeBody),
  };
}

/// Icon for a failure kind. Distinct glyphs because the kinds call for
/// different reactions: a wrong clock is the user's to fix, a blocked
/// network is not fixable here at all, and a control-channel fault is ours.
IconData torFailureIcon(TorFailureKind kind) => switch (kind) {
      TorFailureKind.offline => Icons.wifi_off_outlined,
      TorFailureKind.censored => Icons.block_outlined,
      TorFailureKind.clockSkew => Icons.schedule_outlined,
      TorFailureKind.exitPolicy => Icons.public_off_outlined,
      TorFailureKind.controlChannel => Icons.bug_report_outlined,
      TorFailureKind.bootstrapTimeout => Icons.hourglass_empty_outlined,
      TorFailureKind.runtime => Icons.error_outline,
    };

/// Live Tor state for App Settings.
class TorStatusCard extends StatefulWidget {
  const TorStatusCard({super.key});

  @override
  State<TorStatusCard> createState() => _TorStatusCardState();
}

class _TorStatusCardState extends State<TorStatusCard> {
  StreamSubscription<TorStatus>? _sub;
  TorStatus _status = const TorStopped();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _status = TorService.instance.status;
    _sub = TorService.instance.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nothing to report on a platform without a runtime, and nothing to
    // offer with developer mode off — the same gate the proxy dropdown uses.
    if (!TorService.instance.isAvailable) return const SizedBox.shrink();

    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _status;

    final Widget body = switch (s) {
      TorErrored(:final failure) => _error(loc, theme, failure),
      TorUp(:final host, :final port) => _connected(loc, theme, '$host:$port'),
      TorBootstrapping(:final percent, :final summary) =>
        _bootstrapping(loc, theme, percent, summary),
      TorStarting() => _plain(theme, loc.torStatusStarting, indeterminate: true),
      TorStopped() => _plain(theme, loc.torStatusStopped),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Spacing.lg, Spacing.sm, Spacing.lg, Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                s is TorErrored
                    ? torFailureIcon(s.failure.kind)
                    : (s is TorUp
                        ? Icons.verified_user_outlined
                        : Icons.privacy_tip_outlined),
                size: IconSizes.action,
                color: s is TorErrored
                    ? scheme.error
                    : (s is TorUp ? scheme.primary : scheme.onSurfaceVariant),
              ),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Text(loc.torStatusTitle,
                    style: theme.textTheme.labelLarge),
              ),
              HintButton(
                title: loc.torStatusTitle,
                description: loc.torStatusHint,
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          body,
        ],
      ),
    );
  }

  Widget _plain(ThemeData theme, String text, {bool indeterminate = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: theme.textTheme.bodyMedium),
        if (indeterminate) ...[
          const SizedBox(height: Spacing.sm),
          const LinearProgressIndicator(minHeight: Spacing.xs),
        ],
      ],
    );
  }

  Widget _bootstrapping(
      AppLocalizations loc, ThemeData theme, int percent, String? summary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(loc.torStatusBootstrapping(percent),
            style: theme.textTheme.bodyMedium),
        if (summary != null && summary.isNotEmpty)
          Text(
            loc.torStatusPhase(summary),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        const SizedBox(height: Spacing.sm),
        LinearProgressIndicator(
          value: (percent.clamp(0, 100)) / 100.0,
          minHeight: Spacing.xs,
        ),
      ],
    );
  }

  Widget _connected(
      AppLocalizations loc, ThemeData theme, String endpoint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(loc.torStatusConnected, style: theme.textTheme.bodyMedium),
        Text(
          loc.torStatusEndpoint(endpoint),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: Spacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy
                ? null
                : () => _run(TorService.instance.rebuildCircuits),
            icon: const Icon(Icons.refresh, size: IconSizes.action),
            label: Text(loc.torStatusRebuildCircuits),
          ),
        ),
      ],
    );
  }

  Widget _error(
      AppLocalizations loc, ThemeData theme, TorFailure failure) {
    final copy = torFailureCopy(loc, failure.kind);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          copy.title,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.error, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: Spacing.xs),
        Text(copy.body, style: theme.textTheme.bodySmall),
        if (failure.isTransient) ...[
          const SizedBox(height: Spacing.xs),
          Text(loc.torFailTransientNote,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: Spacing.xs),
        // The raw message stays visible rather than living only in the log:
        // the classified copy is a best guess from patterns, and when the
        // guess is wrong this line is what makes that obvious.
        // No `fontFamily: 'monospace'` here: that name resolves on Android
        // and not on iOS, which is the only platform this ships on, so it
        // would silently fall back to a different face than intended.
        Text(
          failure.detail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        Row(
          children: [
            TextButton.icon(
              onPressed:
                  _busy ? null : () => _run(TorService.instance.restart),
              icon: const Icon(Icons.refresh, size: IconSizes.action),
              label: Text(loc.commonRetry),
            ),
            // Only where bridges could actually help. Offering them for a
            // wrong clock or a dead exit pin sends the user down a road
            // that cannot fix their problem (TOR-016).
            if (bridgesMayHelp(failure.kind))
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const TorBridgeSettingsScreen(),
                          ),
                        ),
                icon: const Icon(Icons.alt_route, size: IconSizes.action),
                label: Text(loc.torBridgesTitle),
              ),
          ],
        ),
      ],
    );
  }
}
