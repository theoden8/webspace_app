import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// A launcher group represented by a compact cluster of its site icons.
class WebspaceGroupTile extends StatelessWidget {
  const WebspaceGroupTile({
    super.key,
    required this.webspace,
    required this.sites,
    required this.selected,
    required this.colorIndex,
    required this.onOpen,
    required this.onMenu,
  });

  final Webspace webspace;
  final List<WebViewModel> sites;
  final bool selected;
  final int colorIndex;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  static double extentFor({
    required TextScaler textScaler,
    required TextTheme textTheme,
    required double well,
  }) {
    final title = textTheme.bodyMedium!.copyWith(
      fontSize: LibraryStyle.siteTitleSize,
    );
    final count = textTheme.bodySmall!;
    return well +
        Spacing.md +
        Spacing.sm +
        textScaler.scale(title.fontSize!) * (title.height ?? 1) * 2 +
        textScaler.scale(count.fontSize!) * (count.height ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final well = LibraryStyle.itemWell(webspace.launcherSize);
    final count = AppLocalizations.of(
      context,
    ).webspacesListSiteCount(sites.length);
    final label = '${webspace.name}, $count';
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onLongPress: onMenu,
      child: InkWell(
        borderRadius: BorderRadius.circular(LibraryStyle.radius),
        onTap: onOpen,
        // Let the pointer finish before the sheet covers this tile.
        onLongPressUp: onMenu,
        onSecondaryTap: onMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : Motion.libraryNavigation,
              curve: Motion.libraryCurve,
              width: well,
              height: well,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ExcludeSemantics(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: selected
                              ? theme.colorScheme.primaryContainer
                              : LibraryStyle.group(
                                  theme.brightness,
                                  index: colorIndex,
                                ),
                          borderRadius: BorderRadius.circular(
                            LibraryStyle.radius,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(Spacing.sm),
                          child: _previews(theme),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.md),
            ExcludeSemantics(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      webspace.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: LibraryStyle.siteTitleSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      Icons.check_circle,
                      size: IconSizes.inline,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Spacing.xs),
            ExcludeSemantics(
              child: Text(
                count,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previews(ThemeData theme) {
    final hasRemainder = sites.length > 4;
    final visible = hasRemainder ? 3 : sites.length;
    final remainder = '+${sites.length - visible}';
    Widget cell({required int index}) => DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(index < visible ? 210 : 70),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Center(
        child: index < visible
            ? UnifiedFaviconImage.site(
                sites[index],
                key: ValueKey(sites[index].siteId),
                size:
                    LibraryStyle.previewIcon *
                    LibraryStyle.itemWell(webspace.launcherSize) /
                    LibraryStyle.siteWell,
              )
            : index == 3 && hasRemainder
            ? FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.xs),
                  child: Text(
                    remainder,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
    return Column(
      children: [
        for (var row = 0; row < 2; row++) ...[
          if (row > 0) const SizedBox(height: Spacing.xs),
          Expanded(
            child: Row(
              children: [
                Expanded(child: cell(index: row * 2)),
                const SizedBox(width: Spacing.xs),
                Expanded(child: cell(index: row * 2 + 1)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
