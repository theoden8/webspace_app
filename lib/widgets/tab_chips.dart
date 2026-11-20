import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_address.dart';

/// What a tab chip asks of the page: open a tab, close one, add one. Every
/// one goes through the tabs controller, as the Tabs sheet's do.
typedef TabChipActions = ({
  void Function(WebViewModel site, {required TabId tabId}) open,
  void Function(WebViewModel site, {required TabId tabId}) close,
  void Function(WebViewModel site) add,
});

/// A site's tabs as a row of chips, in the order they were opened, then a +
/// that adds one: the site strip's and the sidebar squares' tabs. One row
/// cannot nest, so a tab opened from another carries a mark.
class TabChips extends StatelessWidget {
  const TabChips({
    super.key,
    required this.site,
    required this.isCurrent,
    required this.actions,
    this.wrap = false,
  });

  final WebViewModel site;

  /// Whether [site] is on screen, so its active tab is the page.
  final bool isCurrent;
  final TabChipActions actions;

  /// Lays the chips out in lines rather than one row (the squares' panel).
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final chips = <Widget>[
      for (final row in TabLifecycleEngine.treeOrder(site.tabs))
        TabChip(
          label: row.tab.title?.isNotEmpty == true
              ? row.tab.title!
              : addressOf(row.tab.url, loc: loc),
          active: isCurrent && row.tab.id == site.activeTabId,
          openedFrom: row.depth > 0,
          onOpen: () => actions.open(site, tabId: row.tab.id),
          onClose: site.tabs.length < 2
              ? null
              : () => actions.close(site, tabId: row.tab.id),
        ),
      IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: IconSizes.action,
        tooltip: loc.tabsNewTab,
        icon: const Icon(Icons.add),
        onPressed: () => actions.add(site),
      ),
    ];
    if (wrap) {
      return Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: chips,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final chip in chips)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: chip,
          ),
      ],
    );
  }
}

/// One tab in [TabChips].
class TabChip extends StatelessWidget {
  const TabChip({
    super.key,
    required this.label,
    required this.active,
    required this.openedFrom,
    required this.onOpen,
    required this.onClose,
  });

  /// The mark of a tab opened from another, found by tests.
  static const Key openedFromMark = ValueKey('tab-chip-opened-from');

  final String label;
  final bool active;
  final bool openedFrom;
  final VoidCallback onOpen;

  /// Null for a site's only tab, which nothing replaces.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loc = AppLocalizations.of(context);
    return Material(
      color: active ? scheme.secondaryContainer : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(
          color: active ? scheme.primary : scheme.outlineVariant,
          width: active ? 1.5 : Chrome.hairlineWidth,
        ),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(Radii.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180, minHeight: 32),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
                start: Spacing.sm, end: onClose == null ? Spacing.sm : 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (openedFrom) ...[
                  Container(
                    key: openedFromMark,
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: active ? FontWeight.w600 : null,
                    ),
                  ),
                ),
                if (onClose case final close?)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 28, height: 28),
                    iconSize: IconSizes.inline,
                    tooltip: loc.tabsCloseTab,
                    icon: const Icon(Icons.close),
                    onPressed: close,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
