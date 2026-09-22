// Shown in place of the page when a navigation was cancelled because the app
// could not establish that it would go through the site's proxy (LEAK-010).
//
// It sits at the widget level for the same reason the Tor bootstrap
// interstitial does: the navigation never happened, so there is no page to
// render an error into, and the webview underneath still holds the document
// the user was on.
//
// There is deliberately no affordance to continue, and none to retry: the
// whole point of the block is that the request would have carried the device
// IP, and BUG-014 once measured a WebView built after the app's
// first frame going direct on its own first load (`later-pair=0 of 2
// proxied`, against a live `pair=2 of 2` control in the same process). So
// reopening the destination on a fresh view cannot be offered as the proxied
// way to reach it. The way out is back, or the setting that caused it.
//
// Spec: openspec/specs/ip-leakage/spec.md.

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/design_tokens.dart';

/// Empty-state glyph, sized as on the Tor bootstrap interstitial: it is the
/// only thing on screen, so it is not an in-row icon.
const double _glyphSize = 56;

/// Width the text column holds itself to, so the sentences stay readable on a
/// tablet pane. A layout measure, not a spacing step.
const double _columnWidth = 360;

class UnproxiedNavigationBlock extends StatelessWidget {
  const UnproxiedNavigationBlock({
    super.key,
    required this.siteName,
    required this.blockedUrl,
    required this.onGoBack,
    required this.onOpenProxySettings,
  });

  /// The site as the user named it, so the block is attributable.
  final String siteName;

  /// Where the cancelled navigation was headed.
  final String blockedUrl;

  final VoidCallback onGoBack;

  final VoidCallback onOpenProxySettings;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final destination = Uri.tryParse(blockedUrl)?.host ?? blockedUrl;

    return Container(
      color: scheme.surface,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Center(
          child: SizedBox(
            width: _columnWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.shield_outlined,
                    size: _glyphSize, color: scheme.primary),
                const SizedBox(height: Spacing.lg),
                Text(
                  loc.unproxiedBlockTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  loc.unproxiedBlockBody(siteName),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Spacing.md),
                Text(
                  loc.unproxiedBlockDestination(destination),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Spacing.md),
                Text(
                  loc.unproxiedBlockWhy,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Spacing.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Spacing.sm,
                  runSpacing: Spacing.xs,
                  children: [
                    FilledButton.icon(
                      onPressed: onGoBack,
                      icon: const Icon(Icons.arrow_back,
                          size: IconSizes.action),
                      label: Text(loc.unproxiedBlockBack),
                    ),
                    TextButton.icon(
                      onPressed: onOpenProxySettings,
                      icon: const Icon(Icons.settings_ethernet,
                          size: IconSizes.action),
                      label: Text(loc.unproxiedBlockProxySettings),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
