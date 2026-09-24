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
import 'package:webspace/screens/tor_bridge_settings.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_bridges.dart' show bridgesMayHelp;
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

    // Centred, but scrollable when the text does not fit: the error branch
    // carries tor's own message at whatever length tor chose, and a large
    // accessibility text scale multiplies it. A Column that overflows shows
    // stripes and swallows the Retry button.
    Widget centered(List<Widget> children) => Container(
      color: scheme.surface,
      padding: const EdgeInsets.all(Spacing.xl),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: SizedBox(
                width: _columnWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Where Tor cannot run at all, `stopped` is not a moment in a start-up,
    // it is the end state (TOR-022): a progress bar for a wait that never
    // finishes, with no Retry (that button is in the failure branch) and no
    // hint that the site's own proxy is the thing to change.
    //
    // Derived from the status this widget is holding, not from the service's
    // live one, so the branch and the state it renders cannot disagree.
    final gate = torGateFor(
      status: s,
      hasNativeTor: TorService.instance.hasNativeRuntime,
      torEnabled:
          ExperimentalFeaturesService.instance.isEnabled(ExperimentalFeature.tor),
    );

    Widget gated({required bool unsupported}) => centered([
      Icon(
        Icons.do_not_disturb_on_outlined,
        size: _glyphSize,
        color: scheme.onSurfaceVariant,
      ),
      const SizedBox(height: Spacing.lg),
      Text(
        unsupported ? loc.torUnavailableTitle : loc.torDeveloperGateTitle,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium,
      ),
      const SizedBox(height: Spacing.sm),
      Text(
        unsupported ? loc.torUnavailableBody : loc.torDeveloperGateBody,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    ]);

    Widget failure(TorErrored s) {
      final copy = torFailureCopy(loc, s.failure.kind);
      final detail = s.failure.detail;
      return centered([
        Icon(
          torFailureIcon(s.failure.kind),
          size: _glyphSize,
          color: scheme.error,
        ),
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
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        // The raw message, as on the status card and for the same reason:
        // the classified copy is a guess from patterns, and this is what
        // makes a wrong guess visible. This screen is where a user is left
        // when a site will not load, so "no idea why" has to end here and
        // not only in Dev Tools.
        Text(
          detail,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        const _TorLogTail(),
        const SizedBox(height: Spacing.md),
        // Same pair as the status card, and for a stronger reason: this is
        // what a user actually sees when a TOR site will not load, while
        // the card is inside App Settings. Naming bridges as the way past a
        // block and then offering no route to them is how the feature was
        // unreachable in the first place.
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton.icon(
              onPressed: _retrying ? null : _retry,
              icon: const Icon(Icons.refresh, size: IconSizes.action),
              label: Text(loc.commonRetry),
            ),
            if (bridgesMayHelp(s.failure.kind))
              TextButton.icon(
                onPressed: _retrying
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
      ]);
    }

    Widget progress() {
      final int? percent = s is TorBootstrapping
          ? s.percent.clamp(0, 100)
          : null;
      final String label = switch (s) {
        TorBootstrapping(:final percent) => loc.torStatusBootstrapping(percent),
        TorStarting() => loc.torStatusStarting,
        _ => loc.torStatusStopped,
      };
      final String? phase = s is TorBootstrapping ? s.summary : null;

      return centered([
        Icon(
          Icons.privacy_tip_outlined,
          size: _glyphSize,
          color: scheme.primary.withValues(alpha: 0.7),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        if (phase != null && phase.isNotEmpty) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            loc.torStatusPhase(phase),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        LinearProgressIndicator(
          value: percent == null ? null : percent / 100.0,
          minHeight: Spacing.xs,
        ),
        const SizedBox(height: Spacing.md),
        const _TorLogTail(),
      ]);
    }

    // Exhaustive over the gate, with no default arm: a new TorGate value
    // will not compile until this says what it looks like. The status alone
    // could not carry that obligation -- `stopped` is two different screens
    // depending on whether anything can start (TOR-022).
    return switch (gate) {
      TorGate.unsupported => gated(unsupported: true),
      TorGate.switchedOff => gated(unsupported: false),
      // Sound by construction: torGateFor returns `errored` only for a
      // TorErrored status, and both read the same `s`.
      TorGate.errored => failure(s as TorErrored),
      TorGate.working => progress(),
    };
  }
}

/// The last few things the runtime and tor said, live.
///
/// Starting Tor is 10 to 30 seconds of nothing on a good network and can be
/// a minute of nothing on a bad one. A bar with no words leaves the user
/// guessing at whether anything is happening at all, and leaves a bug
/// report with nothing in it — which is how a device where tor never opened
/// its control port went unexplained. These lines are not translated: they
/// are diagnostics, the same raw material as the failure detail above.
class _TorLogTail extends StatelessWidget {
  const _TorLogTail();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: LogService.instance,
      builder: (context, _) {
        final lines = LogService.instance
            .recent({kTorLogTag, kTorDaemonLogTag})
            .map((e) => e.message)
            .toList();
        if (lines.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.xs),
                child: Text(
                  line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
