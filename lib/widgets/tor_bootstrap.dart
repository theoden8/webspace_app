// Interstitial shown in place of a Tor-bound webview while the runtime is
// starting, bootstrapping or errored. Sits at the widget level so no
// InAppWebView is constructed against a dead SOCKS endpoint (which is what
// makes a fresh site whose bootstrap raced the render come up direct — the
// fail-open flavour of TOR-008).
//
// It also has to say what is happening. The first cut rendered a mute
// progress bar and a mute error glyph, which left a user staring at a blank
// tab with no way to tell "connecting" from "this network blocks Tor"
// (TOR-013, TOR-015).
//
// Spec: openspec/specs/tor-proxy/spec.md.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/tor_status_card.dart'
    show torFailureCopy, torFailureIcon;

/// Empty-state glyph, larger than anything in [IconSizes] — those name
/// in-row and in-button icons, and this one is the only thing on screen.
const double _glyphSize = 56;

/// Width the text column and progress bar share. A layout measure rather
/// than a spacing step, so it is not a [Spacing] value.
const double _columnWidth = 320;

/// Renders a placeholder for a TOR-bound webview whose runtime is not yet
/// [TorUp]. Subscribes to [TorService.statusStream] for its own display;
/// the parent (WebSpacePage's status listener, or the nested screen's) is
/// what swaps it out for the real webview once Tor reaches [TorUp].
class TorBootstrapPlaceholder extends StatefulWidget {
  const TorBootstrapPlaceholder({super.key});

  @override
  State<TorBootstrapPlaceholder> createState() =>
      _TorBootstrapPlaceholderState();
}

class _TorBootstrapPlaceholderState extends State<TorBootstrapPlaceholder> {
  StreamSubscription<TorStatus>? _sub;
  TorStatus _status = const TorStopped();
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _status = TorService.instance.status;
    _sub = TorService.instance.statusStream.listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
    });
    // Kick a start attempt if nothing else has. Idempotent under refcount.
    TorService.instance.maybeStart('interstitial:${identityHashCode(this)}');
  }

  @override
  void dispose() {
    _sub?.cancel();
    // The refcount holder is per-placeholder-instance; releasing it here is
    // symmetric with the acquire above. The site itself still holds its own
    // refcount via _syncTorHolders, so the runtime does not shut down just
    // because the placeholder went away.
    TorService.instance.release('interstitial:${identityHashCode(this)}');
    super.dispose();
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await TorService.instance.restart();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _status;

    Widget centered(List<Widget> children) => Container(
          color: scheme.surface,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(Spacing.xl),
          child: SizedBox(
            width: _columnWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: children,
            ),
          ),
        );

    if (s is TorErrored) {
      final copy = torFailureCopy(loc, s.failure.kind);
      return centered([
        Icon(torFailureIcon(s.failure.kind),
            size: _glyphSize, color: scheme.error),
        const SizedBox(height: Spacing.lg),
        Text(
          copy.title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(color: scheme.error),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          copy.body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Spacing.md),
        TextButton.icon(
          onPressed: _retrying ? null : _retry,
          icon: const Icon(Icons.refresh, size: IconSizes.action),
          label: Text(loc.commonRetry),
        ),
      ]);
    }

    final int? percent = s is TorBootstrapping ? s.percent.clamp(0, 100) : null;
    final String label = switch (s) {
      TorBootstrapping(:final percent) => loc.torStatusBootstrapping(percent),
      TorStarting() => loc.torStatusStarting,
      _ => loc.torStatusStopped,
    };
    final String? phase = s is TorBootstrapping ? s.summary : null;

    return centered([
      Icon(Icons.privacy_tip_outlined,
          size: _glyphSize, color: scheme.primary.withValues(alpha: 0.7)),
      const SizedBox(height: Spacing.lg),
      Text(label,
          textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
      if (phase != null && phase.isNotEmpty) ...[
        const SizedBox(height: Spacing.xs),
        Text(
          loc.torStatusPhase(phase),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      LinearProgressIndicator(
        value: percent == null ? null : percent / 100.0,
        minHeight: Spacing.xs,
      ),
    ]);
  }
}
