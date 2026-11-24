import 'package:flutter/material.dart';

import 'package:webspace/services/navigation_surface_engine.dart';
import 'package:webspace/settings/navigation_choices.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';

/// Lays the page out with its sidebar: the docked panel or rail beside it,
/// the drawer or the full-screen sidebar over it, and the arrow tab on its
/// left edge, as [surfaces] says. The page takes its new width once a
/// sidebar's motion ends, never every frame: resizing the webview each frame
/// is costly and risks blank surfaces on Android (BUG-001, BUG-002).
class SiteNavigationFrame extends StatefulWidget {
  const SiteNavigationFrame({
    super.key,
    required this.surfaces,
    required this.main,
    required this.panelWidth,
    required this.floatWidth,
    required this.railWidth,
    required this.panel,
    required this.rail,
    required this.handleFraction,
    required this.revealsOverlay,
    required this.expandsOnHover,
    required this.onArrowTap,
    required this.onSettle,
    required this.onReveal,
    required this.onDismissFloat,
    required this.onHandleMoved,
    required this.onResize,
  });

  final NavigationSurfaces surfaces;

  /// The page: the site strip never shows with the sidebar, so this is the
  /// page and its URL bar. Kept mounted whatever the sidebar does.
  final Widget main;

  /// The docked sidebar's width, and the drawer's or the full-screen
  /// sidebar's.
  final double panelWidth;
  final double floatWidth;
  final double railWidth;

  /// The open sidebar at a width; [floating] over the page or docked.
  final Widget Function(double width, {required bool floating}) panel;
  final Widget rail;

  /// The arrow tab's height along the edge, from 0 to 1.
  final double handleFraction;

  /// Whether the arrow tab reveals a sidebar over the page (full screen set
  /// to Button) rather than bringing the docked one back.
  final bool revealsOverlay;

  /// Whether the rail opens over the page while a pointer rests on it.
  final bool expandsOnHover;

  final VoidCallback onArrowTap;

  /// Where a pull of the arrow tab let go.
  final ValueChanged<SidebarState> onSettle;

  /// A pull of the arrow tab in full screen: shown or not.
  final ValueChanged<bool> onReveal;

  /// A tap outside the drawer or the full-screen sidebar.
  final VoidCallback onDismissFloat;
  final ValueChanged<double> onHandleMoved;

  /// The width the edge drag let go at.
  final ValueChanged<double> onResize;

  @override
  State<SiteNavigationFrame> createState() => SiteNavigationFrameState();
}

enum _Content { none, rail, panel }

class SiteNavigationFrameState extends State<SiteNavigationFrame> {
  late _Content _content = _contentOf(widget.surfaces.dock);
  late double _padding = _dockWidth(widget.surfaces.dock);

  /// How far a pull of the arrow tab has come, while it lasts.
  double? _pull;

  /// The arrow tab's travel along the edge, while a move lasts.
  double _moved = 0;

  /// The width the edge drag shows as a guide, while it lasts.
  double? _resizeTo;

  /// The drawer or full-screen sidebar sliding away: still built until its
  /// motion ends.
  bool _floatLeaving = false;

  /// A pointer rests on the rail, or on the sidebar it opened beside it.
  bool _overRail = false;
  bool _overFlyout = false;

  bool get _flyout =>
      (_overRail || _overFlyout) &&
      widget.expandsOnHover &&
      _content == _Content.rail;

  static _Content _contentOf(SidebarDock dock) => switch (dock) {
    SidebarDock.none => _Content.none,
    SidebarDock.rail => _Content.rail,
    SidebarDock.full => _Content.panel,
  };

  double _dockWidth(SidebarDock dock) => switch (dock) {
    SidebarDock.none => 0,
    SidebarDock.rail => widget.railWidth,
    SidebarDock.full => widget.panelWidth,
  };

  double _contentWidth(_Content content) => switch (content) {
    _Content.none => 0,
    _Content.rail => widget.railWidth,
    _Content.panel => widget.panelWidth,
  };

  bool get _still => MediaQuery.of(context).disableAnimations;

  @override
  void didUpdateWidget(SiteNavigationFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.surfaces.dock != widget.surfaces.dock) {
      _overRail = false;
      _overFlyout = false;
    }
    final next = _contentOf(widget.surfaces.dock);
    // Growing, the new content shows at once and the box grows over the
    // page; shrinking, the old content stays until the box has shrunk.
    if (_contentWidth(next) >= _contentWidth(_content)) _content = next;
    final wasFloating = oldWidget.surfaces.float != SidebarFloat.none;
    final floating = widget.surfaces.float != SidebarFloat.none;
    if (wasFloating && !floating) _floatLeaving = true;
    if (floating) _floatLeaving = false;
    // A motion of no length ends as it starts, inside this build, so its end
    // is applied here rather than from a callback.
    if (_still) {
      _content = next;
      _padding = _dockWidth(widget.surfaces.dock);
      _floatLeaving = false;
    }
  }

  void _landed() => setState(() {
    _content = _contentOf(widget.surfaces.dock);
    _padding = _dockWidth(widget.surfaces.dock);
  });

  Widget _contentWidget(_Content content) => switch (content) {
    _Content.none => const SizedBox.shrink(),
    _Content.rail => widget.rail,
    _Content.panel => widget.panel(widget.panelWidth, floating: false),
  };

  void _endPull() {
    final pull = _pull ?? 0;
    setState(() => _pull = null);
    if (widget.revealsOverlay) {
      widget.onReveal(pull > widget.floatWidth / 2);
    } else {
      // On a phone the open sidebar is the drawer, as wide as [floatWidth].
      widget.onSettle(
        settleSidebar(
          visible: pull,
          width: widget.floatWidth,
          rail: widget.railWidth,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = widget.surfaces;
    final dockTarget = _dockWidth(surfaces.dock);
    final morph = _still ? Duration.zero : Motion.layoutMorph;
    final slide = _still ? Duration.zero : Motion.settle;
    final floating = surfaces.float != SidebarFloat.none;
    return LayoutBuilder(
      builder: (context, box) {
        final handleTop =
            (box.maxHeight - SidebarArrowTab.size.height) *
                widget.handleFraction +
            _moved;
        return Stack(
          children: [
            Positioned.fill(left: _padding, child: widget.main),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: MouseRegion(
                onEnter: (_) => setState(() => _overRail = true),
                onExit: (_) => setState(() => _overRail = false),
                child: AnimatedContainer(
                  duration: morph,
                  curve: Motion.layoutCurve,
                  width: dockTarget,
                  clipBehavior: Clip.hardEdge,
                  decoration: const BoxDecoration(),
                  onEnd: _still ? null : _landed,
                  child: OverflowBox(
                    alignment: AlignmentDirectional.centerStart,
                    minWidth: _contentWidth(_content),
                    maxWidth: _contentWidth(_content),
                    child: _contentWidget(_content),
                  ),
                ),
              ),
            ),
            // Beside the rail, not over it: the rail's own controls, its
            // cross among them, stay under the pointer.
            if (_flyout)
              Positioned(
                left: widget.railWidth,
                top: 0,
                bottom: 0,
                width: widget.floatWidth,
                child: MouseRegion(
                  onEnter: (_) => setState(() => _overFlyout = true),
                  onExit: (_) => setState(() => _overFlyout = false),
                  child: Material(
                    elevation: 8,
                    child: widget.panel(widget.floatWidth, floating: true),
                  ),
                ),
              ),
            if (_resizeTo case final to?)
              Positioned(
                left: to,
                top: 0,
                bottom: 0,
                width: 2,
                child: ColoredBox(color: Theme.of(context).colorScheme.primary),
              ),
            // The scrim under a sidebar over the page.
            IgnorePointer(
              ignoring: !floating,
              child: AnimatedOpacity(
                duration: slide,
                opacity: floating ? 1 : 0,
                child: GestureDetector(
                  onTap: widget.onDismissFloat,
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: LibraryStyle.scrimOpacity,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: slide,
              curve: floating
                  ? Easing.emphasizedDecelerate
                  : Easing.emphasizedAccelerate,
              left: floating ? 0 : -widget.floatWidth - 24,
              top: 0,
              bottom: 0,
              width: widget.floatWidth,
              onEnd: _still
                  ? null
                  : () => setState(() => _floatLeaving = false),
              // Built only while shown or sliding away: off screen it would be a
              // whole sidebar nobody sees.
              child: floating || _floatLeaving
                  ? Material(
                      elevation: 8,
                      child: widget.panel(widget.floatWidth, floating: true),
                    )
                  : const SizedBox.shrink(),
            ),
            if (_pull case final pull?)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: pull.clamp(0, widget.floatWidth),
                child: ClipRect(
                  child: OverflowBox(
                    alignment: AlignmentDirectional.centerStart,
                    minWidth: widget.floatWidth,
                    maxWidth: widget.floatWidth,
                    child: widget.panel(widget.floatWidth, floating: true),
                  ),
                ),
              ),
            if (surfaces.arrowTab && _pull == null)
              Positioned(
                left: 0,
                top: handleTop.clamp(
                  0,
                  box.maxHeight - SidebarArrowTab.size.height,
                ),
                child: SidebarArrowTab(
                  onTap: widget.onArrowTap,
                  onPull: (dx) => setState(() => _pull = dx),
                  onPullEnd: _endPull,
                  onMove: (dy) => setState(() => _moved = dy),
                  onMoveEnd: () {
                    final room = box.maxHeight - SidebarArrowTab.size.height;
                    final fraction = room <= 0
                        ? widget.handleFraction
                        : ((room * widget.handleFraction + _moved) / room)
                              .clamp(0.1, 0.9);
                    setState(() => _moved = 0);
                    widget.onHandleMoved(fraction);
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  /// The open sidebar's grip moved by [dx]: a guide line shows the width it
  /// would take.
  void resizeBy(double dx) => setState(
    () => _resizeTo = ((_resizeTo ?? widget.panelWidth) + dx).clamp(200, 420),
  );

  /// The grip let go: the sidebar takes the guide's width.
  void resizeEnd() {
    final to = _resizeTo;
    setState(() => _resizeTo = null);
    if (to != null) widget.onResize(to);
  }
}
