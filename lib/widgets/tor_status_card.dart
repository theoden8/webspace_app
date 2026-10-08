// The one place a user can read what the embedded Tor client is doing.
//
// A privacy feature the user cannot verify is barely a feature, so the card
// reports the state, the bootstrap phase, the live SOCKS endpoint, and — when
// it fails — which kind of failure it is and what to do about it (TOR-013,
// TOR-015).
//
// Gated with the rest of Tor on `TorService.isAvailable` (TOR-007).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/tor_bridge_settings.dart';
import 'package:webspace/services/tor_bridges.dart' show bridgesMayHelp;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// User-facing heading and remedy for a failure kind.
///
/// Shared by the card and the in-webview interstitial so the two cannot
/// drift into describing the same failure differently. Every kind is
/// covered explicitly — the switch is exhaustive over the enum, so a new
/// kind fails to compile rather than silently rendering as "unknown".
({String title, String body}) torFailureCopy(
  AppLocalizations loc, {
  required TorFailureKind kind,
}) {
  return switch (kind) {
    TorFailureKind.offline =>
      (title: loc.torFailOfflineTitle, body: loc.torFailOfflineBody),
    TorFailureKind.censored =>
      (title: loc.torFailCensoredTitle, body: loc.torFailCensoredBody),
    TorFailureKind.clockSkew =>
      (title: loc.torFailClockSkewTitle, body: loc.torFailClockSkewBody),
    TorFailureKind.exitPolicy =>
      (title: loc.torFailExitPolicyTitle, body: loc.torFailExitPolicyBody),
    TorFailureKind.exitCountryData => (
        title: loc.torFailExitCountryDataTitle,
        body: loc.torFailExitCountryDataBody
      ),
    TorFailureKind.controlChannel => (
        title: loc.torFailControlChannelTitle,
        body: loc.torFailControlChannelBody
      ),
    TorFailureKind.bootstrapTimeout =>
      (title: loc.torFailTimeoutTitle, body: loc.torFailTimeoutBody),
    TorFailureKind.runtime =>
      (title: loc.torFailRuntimeTitle, body: loc.torFailRuntimeBody),
    TorFailureKind.externalUnreachable =>
      (title: loc.torFailExternalTitle, body: loc.torFailExternalBody),
    TorFailureKind.externalExitPin =>
      (title: loc.torFailExternalPinTitle, body: loc.torFailExternalPinBody),
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
      TorFailureKind.exitCountryData => Icons.cloud_off_outlined,
      TorFailureKind.controlChannel => Icons.bug_report_outlined,
      TorFailureKind.bootstrapTimeout => Icons.hourglass_empty_outlined,
      TorFailureKind.runtime => Icons.error_outline,
      TorFailureKind.externalUnreachable => Icons.link_off_outlined,
      TorFailureKind.externalExitPin => Icons.public_off_outlined,
    };

/// Retry, and the way to bridges where they could help: what the card and
/// the interstitial both offer after a failure. [busy] disables both.
List<Widget> torRecoveryActions(
  BuildContext context, {
  required TorFailureKind kind,
  required bool busy,
  required VoidCallback onRetry,
}) {
  final loc = AppLocalizations.of(context);
  return [
    TextButton.icon(
      onPressed: busy ? null : onRetry,
      icon: const Icon(Icons.refresh, size: IconSizes.action),
      label: Text(loc.commonRetry),
    ),
    // Only where bridges could actually help. Offering them for a wrong
    // clock or a dead exit pin sends the user down a road that cannot fix
    // their problem (TOR-016).
    if (bridgesMayHelp(kind))
      TextButton.icon(
        onPressed: busy
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TorBridgeSettingsScreen(),
                  ),
                ),
        icon: const Icon(Icons.alt_route, size: IconSizes.action),
        label: Text(loc.torBridgesTitle),
      ),
  ];
}

/// Live Tor state for App Settings.
class TorStatusCard extends StatefulWidget {
  const TorStatusCard({super.key, this.onTap});

  /// Opens the full Tor screen. Null where the card already sits on it.
  final VoidCallback? onTap;

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
    final s = _status;
    // Tor starts when a site or the app-wide proxy first asks for it and does
    // not stop on its own (TOR-002), so `stopped` means nothing uses it and
    // there is nothing here to act on (TOR-004).
    if (!TorService.instance.isAvailable || s is TorStopped) {
      return const SizedBox.shrink();
    }

    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Widget body = switch (s) {
      TorErrored(:final failure) => _error(loc, theme: theme, failure: failure),
      TorUp(:final host, :final port) =>
        _connected(loc, theme: theme, endpoint: '$host:$port'),
      TorBootstrapping(:final percent, :final summary) => _progress(loc,
          theme: theme,
          label: loc.torStatusBootstrapping(percent),
          summary: summary,
          value: percent.clamp(0, 100) / 100.0),
      TorStarting() ||
      TorStopped() =>
        _progress(loc, theme: theme, label: loc.torStatusStarting),
    };

    final card = Padding(
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
              Expanded(
                child: HintedTitle(loc.torStatusTitle,
                    hint: loc.torStatusHint, style: theme.textTheme.labelLarge),
              ),
              if (widget.onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          body,
        ],
      ),
    );
    final onTap = widget.onTap;
    return onTap == null ? card : InkWell(onTap: onTap, child: card);
  }

  /// Starting or bootstrapping: what is happening, tor's own phase name, and
  /// a bar that is indeterminate until there is a [value].
  Widget _progress(AppLocalizations loc,
          {required ThemeData theme,
          required String label,
          String? summary,
          double? value}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          if (summary != null && summary.isNotEmpty)
            Text(
              loc.torStatusPhase(summary),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: Spacing.sm),
          LinearProgressIndicator(value: value, minHeight: Spacing.xs),
        ],
      );

  Widget _connected(AppLocalizations loc,
      {required ThemeData theme, required String endpoint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(loc.torStatusConnected, style: theme.textTheme.bodyMedium),
        Text(
          loc.torStatusEndpoint(endpoint),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        // An external tor has no control port here to send NEWNYM to
        // (TOR-025).
        if (!TorService.instance.isExternal) ...[
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
      ],
    );
  }

  Widget _error(AppLocalizations loc,
      {required ThemeData theme, required TorFailure failure}) {
    final copy = torFailureCopy(loc, kind: failure.kind);
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
          children: torRecoveryActions(
            context,
            kind: failure.kind,
            busy: _busy,
            onRetry: () => _run(TorService.instance.restart),
          ),
        ),
      ],
    );
  }
}
