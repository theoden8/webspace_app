import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_permission_badges.dart';
import 'package:webspace/widgets/tab_count_pill.dart';

/// A site in the drawer's grid. Where the grid can be reordered a long press
/// drags the tile and its menu sits behind a corner button; elsewhere a long
/// press opens the menu.
class SiteGridTile extends StatelessWidget {
  const SiteGridTile({
    super.key,
    required this.site,
    required this.listIndex,
    required this.selected,
    required this.showTabCount,
    required this.onOpen,
    required this.onMenu,
    required this.onReorder,
  });

  final WebViewModel site;

  /// The tile's place in the grid, which a drag carries.
  final int listIndex;
  final bool selected;
  final bool showTabCount;
  final VoidCallback onOpen;

  /// The site's menu, at a global position.
  final void Function(BuildContext context, Offset globalPosition) onMenu;

  /// A tile dragged from grid place `from` dropped on this one; null where
  /// the grid cannot be reordered.
  final void Function(int from, int to)? onReorder;

  @override
  Widget build(BuildContext context) {
    final reorder = onReorder;
    return Semantics(
      label: site.getDisplayName(),
      button: true,
      enabled: true,
      child: reorder != null
          ? _draggable(context, reorder)
          : GestureDetector(
              onLongPressStart: (details) =>
                  onMenu(context, details.globalPosition),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.xl),
                onTap: onOpen,
                child: _content(),
              ),
            ),
    );
  }

  Widget _content() => _SiteGridTileContent(
    site: site,
    selected: selected,
    showTabCount: showTabCount,
  );

  Widget _draggable(BuildContext context, void Function(int, int) reorder) {
    final theme = Theme.of(context);
    // A raw Listener rather than a GestureDetector for the tap: the gesture
    // arena against LongPressDraggable delays or drops taps.
    PointerDownEvent? down;
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != listIndex,
      onAcceptWithDetails: (details) => reorder(details.data, listIndex),
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return LongPressDraggable<int>(
          data: listIndex,
          feedback: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(Radii.xl),
            child: SizedBox(
              width: 80,
              height: 88,
              child: Opacity(opacity: 0.85, child: _content()),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: _content()),
          child: Container(
            decoration: isHovered
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.xl),
                    border: Border.all(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                  )
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => down = event,
                  onPointerUp: (event) {
                    final at = down;
                    down = null;
                    if (at != null &&
                        (event.position - at.position).distance < 20 &&
                        event.timeStamp - at.timeStamp < kDoubleTapTimeout) {
                      onOpen();
                    }
                  },
                  onPointerCancel: (_) => down = null,
                  child: GestureDetector(
                    onSecondaryTapDown: (details) =>
                        onMenu(context, details.globalPosition),
                    child: _content(),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final renderBox = context.findRenderObject() as RenderBox;
                      onMenu(
                        context,
                        renderBox.localToGlobal(
                          Offset(renderBox.size.width - 8, 8),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.more_vert,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant.withAlpha(
                          150,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SiteGridTileContent extends StatelessWidget {
  const _SiteGridTileContent({
    required this.site,
    required this.selected,
    required this.showTabCount,
  });

  final WebViewModel site;
  final bool selected;
  final bool showTabCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          child: isWide ? _wide(theme) : _narrow(theme),
        );
      },
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

  Widget _wide(ThemeData theme) {
    final domain = extractDomain(site.initUrl);
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
