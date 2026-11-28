import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/services/navigation_surface_engine.dart';
import 'package:webspace/settings/navigation_choices.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/services/reduced_motion.dart';

/// The page's history as a swipe from the screen's edge walks it.
class EdgeBack {
  const EdgeBack({required this.canGoBack, required this.goBack});

  final Future<bool> Function() canGoBack;
  final VoidCallback goBack;
}

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
    this.edgeBack,
    required this.onHandleMoved,
    this.onLiftedOff,
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

  /// What a right swipe from the screen's edge over the docked sidebar
  /// walks; null where the edge is not the page's back swipe.
  final EdgeBack? edgeBack;
  final ValueChanged<double> onHandleMoved;

  /// The arrow tab, lifted, let go on the page: where in the page, for the
  /// site strip's button to go to the corner nearest it (TAB-038). Null
  /// where the tab cannot be lifted.
  final ValueChanged<Alignment>? onLiftedOff;

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

  /// The strip of the screen's edge a back swipe starts in, as wide as the
  /// one the webview itself answers to.
  static const double _edgeWidth = 20;

  /// Where the lifted arrow tab is under the finger, while it is.
  Offset? _lifted;

  /// How far a swipe from the edge has pulled the page right.
  double _back = 0;
  bool _backDragging = false;

  /// The page springing back after a swipe from the edge let go.
  bool _backSettling = false;

  /// Whether the page has history to go back to, once asked this swipe.
  bool? _backAllowed;

  /// How far left the finger has dragged the sidebar over the page, while
  /// it drags.
  double? _floatDrag;
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

  bool get _still => ReducedMotion.of(context);

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
    final float = _floatPlace(floating: floating);
    return LayoutBuilder(
      builder: (context, box) {
        final handleTop =
            (box.maxHeight - SidebarArrowTab.size.height) *
                widget.handleFraction +
            _moved;
        return Stack(
          children: [
            // Behind the page as a swipe from the edge pulls it away.
            AnimatedPositioned(
              duration: _backSettling ? slide : Duration.zero,
              curve: Easing.emphasizedDecelerate,
              left: _padding,
              top: 0,
              bottom: 0,
              width: _back,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Opacity(
                    opacity: _backAllowed == false
                        ? 0
                        : (_back / _backThreshold(box)).clamp(0, 1),
                    child: const Icon(Icons.arrow_back_ios_new),
                  ),
                ),
              ),
            ),
            // Moved, never resized, as the swipe pulls it: a resize each
            // frame is what BUG-001 warns of.
            AnimatedPositioned(
              duration: _backSettling ? slide : Duration.zero,
              curve: Easing.emphasizedDecelerate,
              left: _padding + _back,
              top: 0,
              bottom: 0,
              width: box.maxWidth - _padding,
              onEnd: _backSettling
                  ? () => setState(() => _backSettling = false)
                  : null,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  boxShadow: _back > 0 ? Elevations.pulledPage : const [],
                ),
                child: widget.main,
              ),
            ),
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
                child: ColoredBox(
                    color: Theme.of(context).colorScheme.accentIndicator),
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
              duration: _floatDrag == null ? slide : Duration.zero,
              curve: floating
                  ? Easing.emphasizedDecelerate
                  : Easing.emphasizedAccelerate,
              left: float.left,
              top: 0,
              bottom: 0,
              width: float.width,
              onEnd: _still
                  ? null
                  : () => setState(() => _floatLeaving = false),
              // Built only while shown or leaving: closed it would be a whole
              // sidebar nobody sees.
              child: floating || _floatLeaving
                  ? GestureDetector(
                      onHorizontalDragUpdate: (d) => setState(() {
                        _floatDrag = ((_floatDrag ?? 0) + d.delta.dx).clamp(
                          -widget.floatWidth,
                          0,
                        );
                      }),
                      onHorizontalDragEnd: (d) =>
                          _endFloatDrag(velocity: d.primaryVelocity ?? 0),
                      child: AnimatedOpacity(
                        duration: _floatDrag == null ? slide : Duration.zero,
                        opacity: float.opacity,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: AlignmentDirectional.centerStart,
                            minWidth: widget.floatWidth,
                            maxWidth: widget.floatWidth,
                            child: Material(
                              elevation: 8,
                              child: widget.panel(
                                widget.floatWidth,
                                floating: true,
                              ),
                            ),
                          ),
                        ),
                      ),
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
            if (widget.edgeBack case final edge?
                when surfaces.dock != SidebarDock.none)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _edgeWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) => _startBack(edge),
                  onHorizontalDragUpdate: (d) => setState(() {
                    // At the start of the history the page only gives.
                    final pull = _backAllowed == false ? 0.3 : 1.0;
                    _back = (_back + d.delta.dx * pull).clamp(
                      0,
                      box.maxWidth - _padding,
                    );
                  }),
                  onHorizontalDragEnd: (d) => _endBack(
                    edge,
                    goes:
                        _backAllowed != false &&
                        (_back > _backThreshold(box) ||
                            (d.primaryVelocity ?? 0) > 400),
                  ),
                  onHorizontalDragCancel: () => _endBack(edge, goes: false),
                ),
              ),
            if (surfaces.arrowTab && _pull == null)
              Positioned(
                left: 0,
                top: handleTop.clamp(
                  0,
                  box.maxHeight - SidebarArrowTab.size.height,
                ),
                // Kept while lifted, the hold's own gesture, and drawn under
                // the finger instead.
                child: Opacity(
                  opacity: _lifted == null ? 1 : 0,
                  child: SidebarArrowTab(
                    lift: widget.onLiftedOff == null
                        ? null
                        : (
                            onLift: _liftTo,
                            onMove: _liftTo,
                            onDrop: (at) => _dropLift(at, box: box),
                            onCancel: () => setState(() => _lifted = null),
                          ),
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
              ),
            if (_lifted case final at?) ...[
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: DockZone(hot: at.dx < NavigationLift.dockZone),
              ),
              if (at.dx < NavigationLift.dockZone)
                Positioned(
                  left: 0,
                  top: (at.dy - SidebarArrowTab.size.height / 2).clamp(
                    0,
                    box.maxHeight - SidebarArrowTab.size.height,
                  ),
                  child: IgnorePointer(
                    child: ArrowTabFace(
                      color: Theme.of(context).colorScheme.primary,
                      onColor: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                )
              else
                Positioned(
                  left: at.dx - _liftedButton / 2,
                  top: at.dy - _liftedButton / 2,
                  child: IgnorePointer(
                    child: TabBarCornerButton(
                      dragging: true,
                      onTap: () {},
                      moves: const {},
                      onDragBegin: (_) {},
                      onDragUpdate: (_) {},
                      onDragEnd: () {},
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  static const double _liftedButton =
      FloatingButton.padding * 2 + IconSizes.floating;

  void _liftTo(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    setState(() => _lifted = box.globalToLocal(global));
  }

  /// The lifted tab let go: in the dock zone it stays the arrow tab at that
  /// height; on the page the site strip's button takes its place.
  void _dropLift(Offset global, {required BoxConstraints box}) {
    final frame = context.findRenderObject();
    setState(() => _lifted = null);
    if (frame is! RenderBox || !frame.hasSize) return;
    final at = frame.globalToLocal(global);
    if (at.dx < NavigationLift.dockZone) {
      final room = box.maxHeight - SidebarArrowTab.size.height;
      widget.onHandleMoved(
        room <= 0
            ? widget.handleFraction
            : ((at.dy - SidebarArrowTab.size.height / 2) / room).clamp(
                0.1,
                0.9,
              ),
      );
      return;
    }
    widget.onLiftedOff?.call(
      Alignment(
        (at.dx / box.maxWidth * 2 - 1).clamp(-1, 1),
        (at.dy / box.maxHeight * 2 - 1).clamp(-1, 1),
      ),
    );
  }

  double _backThreshold(BoxConstraints box) => (box.maxWidth - _padding) / 3;

  void _startBack(EdgeBack edge) {
    setState(() {
      _backDragging = true;
      _backSettling = false;
      _backAllowed = null;
    });
    unawaited(
      edge.canGoBack().then((can) {
        if (mounted && _backDragging) setState(() => _backAllowed = can);
      }),
    );
  }

  void _endBack(EdgeBack edge, {required bool goes}) {
    setState(() {
      _backDragging = false;
      _backSettling = _back > 0 && !_still;
      _back = 0;
    });
    if (goes) edge.goBack();
  }

  /// Where the drawer or the full-screen sidebar sits. Over a docked rail it
  /// opens out of the rail and closes back into it, narrowing at the edge
  /// and fading to show the rail beneath; with no rail it slides off the
  /// edge. A drag left narrows or moves it with the finger.
  ({double left, double width, double opacity}) _floatPlace({
    required bool floating,
  }) {
    final drag = _floatDrag ?? 0;
    final full = widget.floatWidth;
    final rail = widget.railWidth;
    if (widget.surfaces.dock != SidebarDock.rail) {
      return (left: floating ? drag : -full - 24, width: full, opacity: 1);
    }
    final width = floating ? (full + drag).clamp(rail, full) : rail;
    return (
      left: 0,
      width: width,
      opacity: full <= rail ? 1 : ((width - rail) / (full - rail)).clamp(0, 1),
    );
  }

  /// A drag of the sidebar over the page let go: past a third of its width,
  /// or flicked left, it goes; otherwise it springs back.
  void _endFloatDrag({required double velocity}) {
    final dragged = _floatDrag ?? 0;
    setState(() => _floatDrag = null);
    if (dragged < -widget.floatWidth / 3 || velocity < -400) {
      widget.onDismissFloat();
    }
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
