import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// A collection represented by a folder containing previews of its sites.
class WebspaceFolderTile extends StatelessWidget {
  const WebspaceFolderTile({
    super.key,
    required this.webspace,
    required this.sites,
    required this.selected,
    required this.colorIndex,
    required this.editing,
    required this.onOpen,
    required this.onMenu,
  });

  final Webspace webspace;
  final List<WebViewModel> sites;
  final bool selected;
  final int colorIndex;
  final bool editing;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  static double extentFor(
    double width, {
    required TextScaler textScaler,
    required TextTheme textTheme,
  }) {
    final title = textTheme.titleMedium!;
    final count = textTheme.bodySmall!;
    return width * .94 +
        Spacing.md +
        Spacing.sm +
        textScaler.scale(title.fontSize!) * (title.height ?? 1) * 2 +
        textScaler.scale(count.fontSize!) * (count.height ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = AppLocalizations.of(
      context,
    ).webspacesListSiteCount(sites.length);
    final label = '${webspace.name}, $count';
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onLongPress: editing ? null : onMenu,
      child: InkWell(
        borderRadius: BorderRadius.circular(LibraryStyle.radius),
        onTap: onOpen,
        // Let the pointer finish before the sheet covers this tile.
        onLongPressUp: editing ? null : onMenu,
        onSecondaryTap: onMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return SizedBox(
                  height: width * .94,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ExcludeSemantics(
                          child: ClipPath(
                            clipper: const _FolderClipper(),
                            child: ColoredBox(
                              color: selected
                                  ? Color.alphaBlend(
                                      theme.colorScheme.primary.withAlpha(24),
                                      LibraryStyle.folder(
                                        theme.brightness,
                                        index: 0,
                                      ),
                                    )
                                  : LibraryStyle.folder(
                                      theme.brightness,
                                      index: colorIndex,
                                    ),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  width * .12,
                                  width * .19,
                                  width * .12,
                                  width * .10,
                                ),
                                child: _previews(theme, width: width),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (editing)
                        PositionedDirectional(
                          top: Spacing.sm,
                          end: 0,
                          child: IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).showMenuTooltip,
                            onPressed: onMenu,
                            icon: const Icon(Icons.more_horiz),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: Spacing.md),
            ExcludeSemantics(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      webspace.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
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

  Widget _previews(ThemeData theme, {required double width}) {
    final hasRemainder = sites.length > 4;
    final visible = hasRemainder ? 3 : sites.length;
    final remainder = '+${sites.length - visible}';
    Widget cell({required int index}) => DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(index < visible ? 210 : 70),
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
      child: Center(
        child: index < visible
            ? UnifiedFaviconImage.site(
                sites[index],
                key: ValueKey(sites[index].siteId),
                size: math.min(LibraryStyle.previewIcon, width * .22),
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
          if (row > 0) const SizedBox(height: Spacing.sm),
          Expanded(
            child: Row(
              children: [
                Expanded(child: cell(index: row * 2)),
                const SizedBox(width: Spacing.sm),
                Expanded(child: cell(index: row * 2 + 1)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _FolderClipper extends CustomClipper<Path> {
  const _FolderClipper();
  @override
  Path getClip(Size size) {
    final r = math.min(LibraryStyle.radius, size.width / 8);
    final tab = size.height * .10;
    return Path()
      ..moveTo(r, 0)
      ..lineTo(size.width * .32, 0)
      ..quadraticBezierTo(size.width * .38, 0, size.width * .42, tab)
      ..lineTo(size.width - r, tab)
      ..quadraticBezierTo(size.width, tab, size.width, tab + r)
      ..lineTo(size.width, size.height - r)
      ..quadraticBezierTo(size.width, size.height, size.width - r, size.height)
      ..lineTo(r, size.height)
      ..quadraticBezierTo(0, size.height, 0, size.height - r)
      ..lineTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..close();
  }

  @override
  bool shouldReclip(_FolderClipper oldClipper) => false;
}
