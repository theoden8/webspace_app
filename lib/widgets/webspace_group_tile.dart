import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/launcher_lift.dart';
import 'package:webspace/widgets/launcher_row.dart';

/// A launcher group represented by a compact cluster of its site icons, over
/// its name, or [list] of the way to a row beside it (WEBSPACE-015).
class WebspaceGroupTile extends StatelessWidget {
  const WebspaceGroupTile({
    super.key,
    required this.webspace,
    required this.sites,
    required this.selected,
    required this.onOpen,
    required this.onMenu,
    this.list = 0,
  });

  final Webspace webspace;
  final List<WebViewModel> sites;
  final bool selected;
  final VoidCallback onOpen;

  /// The group's menu, at a global position.
  final ValueChanged<Offset> onMenu;

  /// How far the tile has turned into a row: 0 its cluster over its name, 1
  /// its cluster at the start of a row beside its name and site count.
  final double list;

  /// Where a tile laid out at [tile], [list] of the way to a row, draws its
  /// well, which an open group grows out of and closes back into.
  static Rect wellIn(
    Rect tile, {
    required double list,
    required TextDirection direction,
  }) => LauncherMorphTile.wellIn(
    tile,
    grid: _gridWell,
    list: list,
    direction: direction,
  );

  static Rect _gridWell(Size tile) => Rect.fromLTWH(
    tile.width / 2 - LibraryStyle.siteWell / 2,
    0,
    LibraryStyle.siteWell,
    LibraryStyle.siteWell,
  );

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
    const well = LibraryStyle.siteWell;
    final count = AppLocalizations.of(
      context,
    ).webspacesListSiteCount(sites.length);
    final label = '${webspace.name}, $count';
    return Semantics(
      label: label,
      selected: selected,
      child: LauncherLift<WebspaceId>(
        data: webspace.isAll ? null : webspace.id,
        onOpen: onOpen,
        onMenu: onMenu,
        child: ExcludeSemantics(
          child: LauncherMorphTile(
            list: list,
            icon: (
              well: _gridWell,
              caption: _caption(theme, count: count),
              captionHeight:
                  extentFor(
                    textScaler: MediaQuery.textScalerOf(context),
                    textTheme: theme.textTheme,
                    well: well,
                  ) -
                  well,
              corner: const [],
            ),
            well: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : Motion.settle,
              width: well,
              height: well,
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(LibraryStyle.radius),
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: LibraryStyle.selectionWidth,
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: LibraryStyle.group(theme.brightness, id: webspace.id),
                  borderRadius: BorderRadius.circular(LibraryStyle.radius),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: _previews(theme),
                ),
              ),
            ),
            row: LauncherRowText(
              name: webspace.name,
              detail: count,
              trailing: [if (selected) _check(theme)],
            ),
          ),
        ),
      ),
    );
  }

  Widget _check(ThemeData theme) => Icon(
    Icons.check_circle,
    size: IconSizes.inline,
    color: theme.colorScheme.primary,
  );

  /// The name under the cluster, marked while selected, over the site count.
  Widget _caption(ThemeData theme, {required String count}) => Column(
    children: [
      const SizedBox(height: Spacing.md),
      Row(
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
            _check(theme),
          ],
        ],
      ),
      const SizedBox(height: Spacing.xs),
      Text(
        count,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

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
                size: LibraryStyle.previewIcon,
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
