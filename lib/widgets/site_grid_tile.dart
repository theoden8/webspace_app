import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/launcher_lift.dart';
import 'package:webspace/widgets/launcher_row.dart';
import 'package:webspace/widgets/site_address.dart';
import 'package:webspace/widgets/site_permission_badges.dart';
import 'package:webspace/widgets/webspace_name.dart';
import 'package:webspace/widgets/tab_count_pill.dart';

enum SiteGridTileLayout { compact, library }

/// A site in a launcher grid: the drawer's, or the library's. A long press
/// lifts it, for its menu or a drag through its grid ([LauncherLift]); the
/// drawer's smaller tiles also keep the menu behind a corner button.
class SiteGridTile extends StatelessWidget {
  const SiteGridTile({
    super.key,
    required this.site,
    required this.listIndex,
    required this.selected,
    required this.showTabCount,
    required this.onOpen,
    required this.onMenu,
    this.layout = SiteGridTileLayout.compact,
    this.webspaces = const [],
    this.lookalike = false,
    this.list = 0,
  }) : assert(
         list == 0 || layout == SiteGridTileLayout.library,
         'only a library tile turns into a row',
       );

  final WebViewModel site;

  /// The tile's place in its grid's saved order, which a drag carries.
  final int listIndex;
  final bool selected;
  final bool showTabCount;
  final SiteGridTileLayout layout;
  final List<Webspace> webspaces;

  /// Whether another site shows the same icon (`sitesSharingAnIcon`).
  final bool lookalike;

  /// How far a library tile has turned into a row: 0 its icon over its name,
  /// 1 its icon at the start of a row beside its name and host
  /// (WEBSPACE-015).
  final double list;

  final VoidCallback onOpen;

  /// The site's menu, at a global position.
  final void Function(BuildContext context, {required Offset globalPosition})
  onMenu;

  /// A library tile's height in a column [width] wide, under [webspaceCount]
  /// webspace labels.
  static double extentFor(
    BuildContext context, {
    required double width,
    required int webspaceCount,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final well = LibraryStyle.wellFor(width: width);
    if (_packed(context, width: width)) {
      return well + Spacing.sm + _packedCaption(context);
    }
    final label = Theme.of(context).textTheme.labelSmall!;
    final rows = webspaceCount.clamp(0, LibraryStyle.membershipLimit);
    return well +
        Spacing.xl +
        scaler.scale(58) +
        rows *
            (scaler.scale(label.fontSize!) * (label.height ?? 1) +
                Spacing.xs * 3);
  }

  /// Whether a library tile [width] wide is in a column narrower than Grid
  /// lays icons in, as Automatic layout packs them: its caption is one line.
  static bool _packed(BuildContext context, {required double width}) =>
      width < LibraryStyle.iconColumnMin(MediaQuery.textScalerOf(context));

  static double _packedCaption(BuildContext context) {
    final title = Theme.of(context).textTheme.bodyMedium!;
    return Spacing.xs +
        MediaQuery.textScalerOf(context).scale(LibraryStyle.siteTitleSize) *
            (title.height ?? 1);
  }

  /// Where a library tile laid out at [tile], [list] of the way to a row,
  /// draws its icon's well, which the site's card grows out of as it opens
  /// and shrinks into as it closes.
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

  static Rect _gridWell(Size tile) {
    final well = LibraryStyle.wellFor(width: tile.width);
    return Rect.fromLTWH(tile.width / 2 - well / 2, Spacing.sm, well, well);
  }

  /// The colour [site]'s icon is marked in: its container's, only where the
  /// icon alone does not tell the site apart, because another site shows the
  /// same one ([lookalike]) or it has none of its own ([missing]); else none
  /// (WEBSPACE-014).
  static Color? markOf(
    WebViewModel site, {
    required Brightness brightness,
    required bool lookalike,
    required bool missing,
  }) => lookalike || missing
      ? containerColorOf(site, brightness: brightness)
      : null;

  /// The fill of a library tile's well, which the site's card starts from:
  /// tinted with its [mark], or neutral where there is none.
  static Color wellColor(Color? mark, {required ThemeData theme}) =>
      mark == null
      ? theme.colorScheme.surfaceContainerHighest
      : Color.alphaBlend(
          mark.withAlpha(LibraryStyle.siteTintAlpha),
          theme.colorScheme.surface,
        );

  @override
  Widget build(BuildContext context) {
    final lift = LauncherLift<int>(
      data: listIndex,
      onOpen: onOpen,
      onMenu: (at) => onMenu(context, globalPosition: at),
      child: _SiteGridTileContent(
        site: site,
        selected: selected,
        showTabCount: showTabCount,
        layout: layout,
        webspaces: webspaces,
        lookalike: lookalike,
        list: list,
      ),
    );
    return Semantics(
      label: [
        site.getDisplayName(),
        if (layout == SiteGridTileLayout.library)
          ...webspaces.map((w) => w.name),
      ].join(', '),
      child: layout == SiteGridTileLayout.library
          ? lift
          : Stack(
              fit: StackFit.expand,
              children: [
                lift,
                Positioned(
                  top: 2,
                  right: 2,
                  child: ExcludeSemantics(child: _cornerMenu(context)),
                ),
              ],
            ),
    );
  }

  Widget _cornerMenu(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () {
      final renderBox = context.findRenderObject()! as RenderBox;
      onMenu(
        context,
        globalPosition: renderBox.localToGlobal(
          Offset(renderBox.size.width - 8, 8),
        ),
      );
    },
    child: Padding(
      padding: const EdgeInsets.all(4.0),
      child: Icon(
        Icons.more_vert,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(150),
      ),
    ),
  );
}

class _SiteGridTileContent extends StatelessWidget {
  const _SiteGridTileContent({
    required this.site,
    required this.selected,
    required this.showTabCount,
    required this.layout,
    required this.webspaces,
    required this.lookalike,
    required this.list,
  });

  final WebViewModel site;
  final bool selected;
  final bool showTabCount;
  final SiteGridTileLayout layout;
  final List<Webspace> webspaces;
  final bool lookalike;
  final double list;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (layout == SiteGridTileLayout.library) return _library(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > constraints.maxHeight * 1.5;
        return Container(
          decoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.xl),
                  color: theme.colorScheme.primaryContainer.withAlpha(80),
                )
              : null,
          padding: isWide
              ? const EdgeInsets.symmetric(vertical: 4, horizontal: 12)
              : const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: isWide ? _wide(context) : _narrow(theme),
        );
      },
    );
  }

  Widget _library(BuildContext context) => LayoutBuilder(
    builder: (context, cell) => _libraryIn(context, width: cell.maxWidth),
  );

  Widget _libraryIn(BuildContext context, {required double width}) =>
      LauncherMorphTile(
        list: list,
        icon: (
          well: SiteGridTile._gridWell,
          caption: SiteGridTile._packed(context, width: width)
              ? _packedName(context)
              : _caption(context),
          captionHeight:
              SiteGridTile.extentFor(
                context,
                width: width,
                webspaceCount: webspaces.length,
              ) -
              LibraryStyle.wellFor(width: width) -
              Spacing.sm,
          corner: [
            if (showTabCount)
              TabCountPill(count: site.tabs.length, active: selected),
          ],
        ),
        well: _well(context),
        row: LauncherRowText(
          name: site.getDisplayName(),
          detail: addressOf(site.initUrl, loc: AppLocalizations.of(context)),
          trailing: [
            SitePermissionBadges(model: site, iconSize: IconSizes.inline),
            if (showTabCount) ...[
              const SizedBox(width: Spacing.sm),
              TabCountPill(count: site.tabs.length, active: selected),
            ],
          ],
        ),
      );

  Widget _well(BuildContext context) {
    final theme = Theme.of(context);
    const well = LibraryStyle.siteWell;
    return UnifiedFaviconImage.site(
      site,
      size: LibraryStyle.siteIcon,
      frame: (context, {required missing, required icon}) {
        final mark = SiteGridTile.markOf(
          site,
          brightness: theme.brightness,
          lookalike: lookalike,
          missing: missing,
        );
        return AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : Motion.settle,
          width: well,
          height: well,
          decoration: BoxDecoration(
            color: SiteGridTile.wellColor(mark, theme: theme),
            border: mark == null
                ? null
                : Border.all(color: mark, width: LibraryStyle.selectionWidth),
            borderRadius: BorderRadius.circular(LibraryStyle.radius),
          ),
          foregroundDecoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(LibraryStyle.radius),
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: LibraryStyle.selectionWidth,
                  ),
                )
              : null,
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          child: icon,
        );
      },
    );
  }

  /// The name under a packed icon on one line, beside its grants.
  Widget _packedName(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              site.getDisplayName(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: LibraryStyle.siteTitleSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SitePermissionBadges(model: site, iconSize: IconSizes.inline),
        ],
      ),
    );
  }

  /// The name under a grid tile's icon, its grants and its webspaces.
  Widget _caption(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: Spacing.sm),
        Text(
          site.getDisplayName(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: LibraryStyle.siteTitleSize,
            fontWeight: FontWeight.w500,
          ),
        ),
        Flexible(
          child: SitePermissionBadges(model: site, iconSize: IconSizes.inline),
        ),
        if (webspaces.isNotEmpty) _webspaceLabels(context),
      ],
    );
  }

  Widget _webspaceLabels(BuildContext context) {
    final theme = Theme.of(context);
    final visible = webspaces.take(LibraryStyle.membershipLimit).toList();
    final remaining = webspaces.length - visible.length;
    final remainingLabel = '+$remaining';
    return ExcludeSemantics(
      child: Column(
        children: [
          for (final webspace in visible)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Container(
                      decoration: BoxDecoration(
                        color: LibraryStyle.group(
                          theme.brightness,
                          id: webspace.id,
                        ),
                        borderRadius: BorderRadius.circular(Radii.xl),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xs,
                      ),
                      child: WebspaceName(
                        webspace,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                  if (identical(webspace, visible.last) && remaining > 0) ...[
                    const SizedBox(width: Spacing.xs),
                    Text(remainingLabel, style: theme.textTheme.labelSmall),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _favicon(
    ThemeData theme, {
    required double box,
    required double icon,
    required double radius,
  }) => Container(
    width: box,
    height: box,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: theme.colorScheme.surfaceContainerHighest,
    ),
    clipBehavior: Clip.antiAlias,
    child: Center(child: UnifiedFaviconImage.site(site, size: icon)),
  );

  Widget _wide(BuildContext context) {
    final theme = Theme.of(context);
    final domain = addressOf(
      site.initUrl,
      loc: AppLocalizations.of(context),
    );
    return Row(
      children: [
        _favicon(theme, box: 36, icon: 28, radius: Radii.lg),
        const SizedBox(width: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, textArea) => Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        site.getDisplayName(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      Text(
                        domain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                // The name keeps at least half the room; grants past that
                // wrap onto another row, which the tile's height has room for.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: textArea.maxWidth / 2),
                  child: SitePermissionBadges(model: site, iconSize: 12),
                ),
              ],
            ),
          ),
        ),
        if (showTabCount)
          TabCountPill(count: site.tabs.length, active: selected),
      ],
    );
  }

  Widget _narrow(ThemeData theme) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Stack(
        // The badge strip is anchored to the favicon's bottom edge and
        // bounded by its width, so a second row of badges grows up over
        // the favicon; the tile has no spare vertical room to stack it
        // below the name.
        clipBehavior: Clip.none,
        children: [
          _favicon(theme, box: 48, icon: 36, radius: Radii.xl),
          Positioned(
            left: 0,
            right: 0,
            bottom: -2,
            child: Center(
              child: SitePermissionBadges(
                model: site,
                iconSize: 9,
                overlay: true,
              ),
            ),
          ),
          // The tab count rides the favicon's top corner: the tile has no
          // spare row, and the permission badges own the bottom edge.
          if (showTabCount)
            Positioned(
              top: -2,
              right: -2,
              child: TabCountPill(count: site.tabs.length, active: selected),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Flexible(
        child: Text(
          site.getDisplayName(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11),
        ),
      ),
    ],
  );
}
