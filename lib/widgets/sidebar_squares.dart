import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/open_sites.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tab_chips.dart';
import 'package:webspace/widgets/tab_count_pill.dart';

/// The open sidebar's squares: the sites as a grid, three to a row, and an
/// open site's tabs as chips in a panel under its row, pointing at its
/// square, opening the way the site strip's chips do.
class SidebarSquares extends StatelessWidget {
  const SidebarSquares({
    super.key,
    required this.sites,
    required this.current,
    required this.open,
    required this.onSquare,
    required this.onToggleOpen,
    required this.actions,
    required this.onMenu,
  });

  static const int columns = 3;

  final List<WebViewModel> sites;
  final WebViewModel? current;
  final OpenSites open;

  /// A tap on a square: another site opens; the site on screen's tabs open
  /// or close.
  final ValueChanged<WebViewModel> onSquare;

  /// The arrow in a square's corner: its tabs open or close without
  /// switching site.
  final ValueChanged<WebViewModel> onToggleOpen;
  final TabChipActions actions;

  /// A long press or a secondary click on a square: the site's menu, as the
  /// drawer's tiles give it.
  final void Function(
    BuildContext context, {
    required WebViewModel site,
    required Offset position,
  })
  onMenu;

  bool _isOpen(WebViewModel site) =>
      site.effectiveTabsEnabled &&
      open.isOpen(site.siteId, current: current?.siteId);

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var r = 0; r < sites.length; r += columns) {
      final row = sites.sublist(r, (r + columns).clamp(0, sites.length));
      rows.add(
        Row(
          children: [
            for (var c = 0; c < columns; c++)
              Expanded(
                child: c < row.length
                    ? Padding(
                        padding: const EdgeInsets.all(Spacing.xs),
                        child: _Square(
                          site: row[c],
                          on: identical(row[c], current),
                          opened: _isOpen(row[c]),
                          onTap: () => onSquare(row[c]),
                          onMenu: (context, {required position}) =>
                              onMenu(context, site: row[c], position: position),
                          onToggle: row[c].effectiveTabsEnabled
                              ? () => onToggleOpen(row[c])
                              : null,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
          ],
        ),
      );
      for (var c = 0; c < row.length; c++) {
        if (_isOpen(row[c])) {
          rows.add(
            _Panel(
              notch: (c + 0.5) / columns,
              child: TabChips(
                site: row[c],
                isCurrent: identical(row[c], current),
                actions: actions,
                wrap: true,
              ),
            ),
          );
        }
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      children: rows,
    );
  }
}

class _Square extends StatelessWidget {
  const _Square({
    required this.site,
    required this.on,
    required this.opened,
    required this.onTap,
    required this.onMenu,
    required this.onToggle,
  });

  final WebViewModel site;
  final bool on;
  final bool opened;
  final VoidCallback onTap;
  final void Function(BuildContext context, {required Offset position}) onMenu;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loc = AppLocalizations.of(context);
    final count = site.effectiveTabsEnabled ? site.tabs.length : 1;
    return Material(
      color: on ? scheme.secondaryContainer : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(
          color: on ? scheme.accentIndicator : scheme.outlineVariant,
          width: on ? 1.5 : Chrome.hairlineWidth,
        ),
      ),
      child: GestureDetector(
        // A semantic long press would open the menu at no position; the
        // custom action below opens it at the square.
        excludeFromSemantics: true,
        onLongPressStart: (d) => onMenu(context, position: d.globalPosition),
        onSecondaryTapUp: (d) => onMenu(context, position: d.globalPosition),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.lg),
          child: Semantics(
            selected: on,
            customSemanticsActions: {
              CustomSemanticsAction(label: loc.homeMenuTooltip): () {
                final box = context.findRenderObject()! as RenderBox;
                onMenu(context,
                    position: box.localToGlobal(box.size.center(Offset.zero)));
              },
            },
            child: Stack(
              alignment: AlignmentDirectional.topCenter,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: Spacing.sm,
                    horizontal: Spacing.xs,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UnifiedFaviconImage.site(site, size: 28),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        site.getDisplayName(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: on ? FontWeight.w600 : null,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onToggle case final toggle?)
                  PositionedDirectional(
                    top: 0,
                    start: 0,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      iconSize: IconSizes.inline,
                      tooltip: opened
                          ? loc.stripHideSiteTabs(site.getDisplayName())
                          : loc.stripShowSiteTabs(site.getDisplayName()),
                      icon: Icon(
                        opened
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                      ),
                      onPressed: toggle,
                    ),
                  ),
                if (count > 1 && !opened)
                  PositionedDirectional(
                    top: Spacing.xs,
                    end: Spacing.xs,
                    child: TabCountPill(count: count, active: on),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A site's tabs under its row, a notch pointing up at its square.
class _Panel extends StatelessWidget {
  const _Panel({required this.notch, required this.child});

  /// Where the square sits along the row, from 0 to 1.
  final double notch;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.xs, 6, Spacing.xs, Spacing.xs),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: child,
          ),
          Positioned.fill(
            top: -6,
            child: Align(
              alignment: Alignment(notch * 2 - 1, -1),
              child: CustomPaint(
                size: const Size(14, 7),
                painter: _Notch(color: color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notch extends CustomPainter {
  _Notch({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Notch old) => old.color != color;
}
