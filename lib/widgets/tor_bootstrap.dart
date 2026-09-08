// Interstitial shown in place of a Tor-bound webview while the runtime is
// starting, bootstrapping or errored. Sits at the widget level so no
// InAppWebView is constructed against a dead SOCKS endpoint (which is what
// makes a fresh site whose bootstrap raced the render come up direct — the
// fail-open flavour of TOR-008).
//
// Deliberately text-free. Localization for the descriptive strings and the
// status card land in a follow-up commit; this file must stay under
// lib/widgets/ (a scanned root) with no `Text(...)` sinks so
// `l10n_no_hardcoded_text` accepts it as migrated without new ARB keys.
//
// Spec: openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md
// (TOR-008 fail-closed before bootstrap, TOR-013 bootstrap surface).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/services/tor_service.dart';
import 'package:webspace/theme/design_tokens.dart';

/// Renders a placeholder for a TOR-bound webview whose runtime is not yet
/// [TorUp]. Subscribes to [TorService.statusStream] so its own progress
/// display updates; the parent (WebSpacePage's status listener, or the
/// nested screen's) is responsible for swapping us out for the real
/// webview once Tor reaches [TorUp].
class TorBootstrapPlaceholder extends StatefulWidget {
  const TorBootstrapPlaceholder({super.key});

  @override
  State<TorBootstrapPlaceholder> createState() =>
      _TorBootstrapPlaceholderState();
}

/// Empty-state glyph, larger than anything in [IconSizes] — those name
/// in-row and in-button icons, and this one is the only thing on screen.
const double _glyphSize = 56;

/// Width of the bootstrap progress bar. A layout measure rather than a
/// spacing step, so it is not a [Spacing] value.
const double _progressWidth = 220;

class _TorBootstrapPlaceholderState extends State<TorBootstrapPlaceholder> {
  StreamSubscription<TorStatus>? _sub;
  TorStatus _status = const TorStopped();

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
    TorService.instance
        .release('interstitial:${identityHashCode(this)}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _status;

    Widget centered(Widget child) => Container(
          color: scheme.surface,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(Spacing.xl),
          child: child,
        );

    if (s is TorErrored) {
      // No retry button: the current TorEngine has no restart-from-error
      // path (acquire is a no-op when the holder set is non-empty, which it
      // is for a site pinned to TOR). The user recovers by switching the
      // site's proxy off Tor and back on, which cycles the refcount and
      // triggers a fresh acquire. A dedicated restart API belongs in the
      // status card follow-on (TOR-013).
      return centered(
        Icon(Icons.cloud_off_outlined, size: _glyphSize, color: scheme.error),
      );
    }

    final double? progress = s is TorBootstrapping
        ? (s.percent.clamp(0, 100) / 100.0).toDouble()
        : null;

    return centered(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.privacy_tip_outlined,
            size: _glyphSize, color: scheme.primary.withOpacity(0.7)),
        const SizedBox(height: Spacing.xl),
        SizedBox(
          width: _progressWidth,
          child: LinearProgressIndicator(
            value: progress,
            minHeight: Spacing.xs,
          ),
        ),
      ],
    ));
  }
}

