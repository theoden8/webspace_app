import 'dart:async';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:webspace/theme/design_tokens.dart';

/// An icon's place in a launcher grid. When the grid moves it (a drop, a
/// menu's Move, a search narrowing the grid) it slides from where it was to
/// where it is now, as icons on a phone's home screen do; one let go after a
/// drag lands from where the finger left it ([LauncherSlotState.landFrom]).
/// The grid must keep the icon's element across the move
/// (`findChildIndexCallback`).
class LauncherSlot extends StatefulWidget {
  const LauncherSlot({super.key, required this.child});

  final Widget child;

  /// The slot around [context], to tell where its icon was let go.
  static LauncherSlotState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<LauncherSlotState>();

  @override
  State<LauncherSlot> createState() => LauncherSlotState();
}

class LauncherSlotState extends State<LauncherSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  late final CurvedAnimation _eased;

  /// How far from its place the running slide started.
  Offset _from = Offset.zero;

  /// Where a drag was let go, in global coordinates, until the slide from
  /// there starts.
  Offset? _dropped;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: Motion.settle,
      value: 1,
    );
    _eased = CurvedAnimation(parent: _slide, curve: Motion.launchCurve);
  }

  @override
  void dispose() {
    _eased.dispose();
    _slide.dispose();
    super.dispose();
  }

  /// The icon was let go with its top-left at [global]; it lands from there.
  void landFrom(Offset global) => setState(() => _dropped = global);

  /// The slot was painted somewhere new, [from] away from where it was seen.
  void _moved(Offset from) {
    if (!mounted) return;
    _dropped = null;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _from = Offset.zero);
      return;
    }
    setState(() => _from = from);
    unawaited(_slide.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _eased,
    builder: (context, child) => _Slot(
      shift: _from * (1 - _eased.value),
      dropped: _dropped,
      onMoved: _moved,
      child: child,
    ),
    child: widget.child,
  );
}

class _Slot extends SingleChildRenderObjectWidget {
  const _Slot({
    required this.shift,
    required this.dropped,
    required this.onMoved,
    super.child,
  });

  final Offset shift;
  final Offset? dropped;
  final ValueChanged<Offset> onMoved;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSlot(onMoved: onMoved)
        ..shift = shift
        ..dropped = dropped;

  @override
  void updateRenderObject(BuildContext context, _RenderSlot renderObject) {
    renderObject
      ..shift = shift
      ..dropped = dropped
      ..onMoved = onMoved
      // The grid moves a slot without repainting it; a rebuild is when a
      // move can have happened, so look again.
      ..markNeedsPaint();
  }
}

/// Paints its child shifted, and notices at paint, once the grid has laid
/// the slot out, that it moved: the first frame after a move already paints
/// it where it was, so it never flashes at its new place before sliding.
class _RenderSlot extends RenderProxyBox {
  _RenderSlot({required this.onMoved});

  ValueChanged<Offset> onMoved;
  Offset? dropped;
  Offset _shift = Offset.zero;
  Offset? _at;
  Offset? _pending;
  Offset? _landed;

  set shift(Offset value) {
    _pending = null;
    if (value == _shift) return;
    _shift = value;
    markNeedsPaint();
  }

  Offset get _effective => _pending ?? _shift;

  /// The grid's offset of the box the sliver laid out for this slot, which
  /// scrolling does not change.
  Offset? _slotOffset() {
    RenderObject? node = this;
    while (node != null) {
      final data = node.parentData;
      if (data is SliverGridParentData) {
        return Offset(data.crossAxisOffset ?? 0, data.layoutOffset ?? 0);
      }
      node = node.parent;
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final at = _slotOffset();
    final drop = dropped;
    Offset? from;
    if (drop != null && drop != _landed) {
      _landed = drop;
      from = drop - localToGlobal(Offset.zero);
    } else if (at != null && _at != null && at != _at) {
      from = _at! - at + _effective;
    }
    if (at != null) _at = at;
    if (from != null) {
      _pending = from;
      final start = from;
      SchedulerBinding.instance.addPostFrameCallback((_) => onMoved(start));
    }
    final child = this.child;
    if (child != null) context.paintChild(child, offset + _effective);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_effective.dx, _effective.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: _effective,
        position: position,
        hitTest: (result, transformed) =>
            super.hitTestChildren(result, position: transformed),
      );
}
