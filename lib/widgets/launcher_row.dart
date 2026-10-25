import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:webspace/theme/design_tokens.dart';

/// What a launcher tile shows as an icon in a grid: where its well sits in a
/// tile of a given size, the caption under it and how tall that caption is,
/// and badges riding the well's top-end corner.
typedef LauncherIcon = ({
  Rect Function(Size tile) well,
  Widget caption,
  double captionHeight,
  List<Widget> corner,
});

/// A launcher tile [list] of the way from an icon over its caption to a row
/// (WEBSPACE-015): its well moves and shrinks from where the grid puts it to
/// the row's start, the caption under it fades early and the row's text fades
/// in late, so a grid and a list of the same items are one tile.
class LauncherMorphTile extends StatelessWidget {
  const LauncherMorphTile({
    super.key,
    required this.list,
    required this.icon,
    required this.well,
    required this.row,
  });

  final double list;
  final LauncherIcon icon;

  /// The well, laid out at [LibraryStyle.siteWell] and scaled to its place.
  final Widget well;

  /// What a row shows beside its well.
  final Widget row;

  /// Where a tile laid out at [tile], [list] of the way to a row, draws its
  /// well, which a card or a folder grows out of and shrinks back into.
  static Rect wellIn(
    Rect tile, {
    required Rect Function(Size tile) grid,
    required double list,
    required TextDirection direction,
  }) {
    final row = Rect.fromLTWH(
      direction == TextDirection.ltr
          ? tile.left + Spacing.lg
          : tile.right - Spacing.lg - LibraryStyle.rowWell,
      tile.center.dy - LibraryStyle.rowWell / 2,
      LibraryStyle.rowWell,
      LibraryStyle.rowWell,
    );
    return Rect.lerp(grid(tile.size).shift(tile.topLeft), row, list)!;
  }

  /// A row's extent: its well's, or its text's where the text is taller.
  static double rowExtentFor(BuildContext context) =>
      _rowText(context) + Spacing.sm * 2;

  static double _rowText(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final text = Theme.of(context).textTheme;
    return math.max(
      LibraryStyle.rowWell,
      scaler.scale(LibraryStyle.rowTitleSize) * (text.bodyMedium!.height ?? 1) +
          scaler.scale(text.bodySmall!.fontSize!) *
              (text.bodySmall!.height ?? 1),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final direction = Directionality.of(context);
      final size = box.biggest;
      final at = wellIn(
        Offset.zero & size,
        grid: icon.well,
        list: list,
        direction: direction,
      );
      final iconShown = 1 - LibraryStyle.gridCaptionOut.transform(list);
      final rowShown = LibraryStyle.rowCaptionIn.transform(list);
      // From the well's end edge to the tile's end edge, which a badge on the
      // well's corner and the row's text count from.
      final afterWell = direction == TextDirection.ltr
          ? size.width - at.right
          : at.left;
      final rowText = _rowText(context);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          if (iconShown > 0)
            Positioned(
              left: at.center.dx - size.width / 2,
              width: size.width,
              top: at.bottom,
              height: icon.captionHeight,
              child: Opacity(opacity: iconShown, child: icon.caption),
            ),
          if (rowShown > 0)
            PositionedDirectional(
              start: size.width - afterWell + Spacing.md,
              end: Spacing.lg,
              top: at.center.dy - rowText / 2,
              height: rowText,
              child: Opacity(
                opacity: rowShown,
                child: Transform.translate(
                  offset: Offset(0, Spacing.sm * (1 - rowShown)),
                  child: row,
                ),
              ),
            ),
          Positioned.fromRect(rect: at, child: FittedBox(child: well)),
          for (final badge in icon.corner)
            PositionedDirectional(
              top: at.top - Spacing.xs,
              end: afterWell - Spacing.xs,
              child: Opacity(opacity: iconShown, child: badge),
            ),
        ],
      );
    },
  );
}

/// [name] in [style], led by [icon] where there is one, drawn as a glyph of
/// the text so it wraps and centres with it.
TextSpan namedSpan(
  BuildContext context, {
  required String name,
  required IconData? icon,
  required TextStyle? style,
}) {
  final size =
      (style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14) *
      LibraryStyle.glyphScale;
  return TextSpan(
    style: style,
    children: [
      if (icon != null) ...[
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(icon, size: MediaQuery.textScalerOf(context).scale(size)),
        ),
        const WidgetSpan(child: SizedBox(width: Spacing.xs)),
      ],
      TextSpan(text: name),
    ],
  );
}

/// A row's text: [name], led by [icon] where it has one, over [detail], then
/// [trailing] at the row's end.
class LauncherRowText extends StatelessWidget {
  const LauncherRowText({
    super.key,
    required this.name,
    this.icon,
    required this.detail,
    required this.trailing,
  });

  final String name;
  final IconData? icon;
  final String detail;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                namedSpan(
                  context,
                  name: name,
                  icon: icon,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: LibraryStyle.rowTitleSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ...trailing,
      ],
    );
  }
}
