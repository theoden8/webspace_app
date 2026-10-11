import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tab_count_pill.dart';

/// The selected webspace's sites along the bottom of the screen. A tap opens
/// a site, a tap on the one on screen opens its tabs (TAB-008), and a long
/// press drags a site to another place where the view can be reordered.
class SiteTabStrip extends StatelessWidget {
  const SiteTabStrip({
    super.key,
    required this.models,
    required this.order,
    required this.current,
    required this.revealed,
    required this.onHide,
    required this.onOpen,
    required this.onShowTabs,
    required this.onReorder,
    required this.menu,
  });

  final List<WebViewModel> models;

  /// Positions in [models], in the order the strip shows them.
  final List<int> order;
  final int? current;

  /// Whether the tab-bar button revealed the strip, whose dismiss control
  /// then lives inside the bar rather than floating above it.
  final bool revealed;
  final VoidCallback onHide;
  final ValueChanged<int> onOpen;
  final VoidCallback onShowTabs;

  /// Null where the view cannot be reordered.
  final void Function(int fromListIndex, {required int to})? onReorder;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: Chrome.bar(isDark: isDark),
          border: Border(
            top: BorderSide(
              color: Chrome.hairline(isDark: isDark),
              width: Chrome.hairlineWidth,
            ),
          ),
        ),
        child: Row(
          children: [
            if (revealed)
              IconButton(
                icon: const Icon(Icons.close),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: onHide,
              ),
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: order.length,
                padding: EdgeInsets.symmetric(horizontal: 4),
                itemBuilder: (context, listIndex) =>
                    _item(listIndex, theme: theme, isDark: isDark),
              ),
            ),
            menu,
          ],
        ),
      ),
    );
  }

  /// One chip. Draggable when the view can be reordered and holds more than
  /// one site. Taps come from a raw [Listener] rather than a
  /// [GestureDetector], which would lose the gesture arena to the
  /// [LongPressDraggable] (the drawer grid tiles do the same).
  Widget _item(
    int listIndex, {
    required ThemeData theme,
    required bool isDark,
  }) {
    final siteIndex = order[listIndex];
    final site = models[siteIndex];
    final isActive = siteIndex == current;
    final content = _content(site, isActive: isActive, theme: theme, isDark: isDark);

    void handleTap() {
      if (isActive) {
        onShowTabs();
      } else {
        onOpen(siteIndex);
      }
    }

    final reorder = onReorder;
    if (reorder == null || order.length < 2) {
      return GestureDetector(onTap: handleTap, child: content);
    }

    Offset? pointerDownPos;
    Duration? pointerDownTime;
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != listIndex,
      onAcceptWithDetails: (details) => reorder(details.data, to: listIndex),
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return LongPressDraggable<int>(
          data: listIndex,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.85, child: content),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: content),
          child: Container(
            decoration: isHovered
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.lg),
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                  )
                : null,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                pointerDownPos = event.position;
                pointerDownTime = event.timeStamp;
              },
              onPointerUp: (event) {
                if (pointerDownPos != null) {
                  final distance = (event.position - pointerDownPos!).distance;
                  final duration = event.timeStamp - pointerDownTime!;
                  if (distance < 20 && duration < kDoubleTapTimeout) {
                    handleTap();
                  }
                }
                pointerDownPos = null;
                pointerDownTime = null;
              },
              onPointerCancel: (_) {
                pointerDownPos = null;
                pointerDownTime = null;
              },
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _content(
    WebViewModel site, {
    required bool isActive,
    required ThemeData theme,
    required bool isDark,
  }) {
    return Container(
      constraints: BoxConstraints(maxWidth: AppPref.tabMaxWidth.value.toDouble()),
      margin: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      padding: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isActive
            ? theme.colorScheme.primaryContainer
            : Chrome.chip(isDark: isDark),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: isActive
            ? Border.all(color: theme.colorScheme.primary, width: 1.5)
            : Border.all(
                color: Chrome.hairline(isDark: isDark),
                width: Chrome.hairlineWidth,
              ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UnifiedFaviconImage(
            url: site.initUrl,
            size: 16,
            proxy: site.outboundProxySettings,
            customIcon: site.customIconPng,
            persist: !site.isArchiveTier,
          ),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              site.getDisplayName(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
          ),
          // Tab count, only once there is more than one: a site with a single
          // tab looks exactly as it did before tabs existed (TAB-008).
          if (site.effectiveTabsEnabled && site.tabs.length > 1)
            TabCountPill(count: site.tabs.length, active: isActive),
        ],
      ),
    );
  }
}
