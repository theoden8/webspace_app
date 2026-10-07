import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/design_tokens.dart';

/// The "N" beside a site's name wherever sites are listed. Shown only once a
/// site has more than one tab: a site with a single tab looks exactly as it
/// did before tabs existed (TAB-008).
class TabCountPill extends StatelessWidget {
  const TabCountPill({super.key, required this.count, required this.active});

  final int count;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _label(count);
    return Padding(
      padding: const EdgeInsets.only(left: Spacing.xs),
      child: Container(
        constraints: const BoxConstraints(minWidth: IconSizes.inline),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: active
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.surface,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// The browser's square-with-a-number in the app bar: how many tabs the site
/// on screen has, and the way into the tab list (TAB-008).
class TabCountButton extends StatelessWidget {
  const TabCountButton({super.key, required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: AppLocalizations.of(context).tabsTooltip,
      onPressed: onPressed,
      icon: Container(
        width: IconSizes.floating,
        height: IconSizes.floating,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.onSurface, width: 2),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Text(
          _label(count),
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
            fontSize: count > 99 ? 8 : null,
          ),
        ),
      ),
    );
  }
}

/// Past two digits the glyph stops being a number and becomes noise.
String _label(int count) => count > 99 ? '99+' : '$count';
