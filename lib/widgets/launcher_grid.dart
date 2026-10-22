import 'dart:async';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A launcher grid's order while one of its icons is dragged: the lifted
/// icon shows at the place it hovers and the others make room, as on a
/// phone's home screen, and letting go anywhere keeps it there
/// (WEBSPACE-011). The grid lays out `shown` (the builder's list), wraps each
/// place in a [LauncherCell], and keeps each icon's element across moves so
/// its `LauncherSlot` slides it.
class LauncherGrid<T extends Object> extends StatefulWidget {
  const LauncherGrid({
    super.key,
    required this.order,
    required this.fixed,
    required this.onMove,
    required this.builder,
  });

  /// The icons' ids, in the grid's saved order.
  final List<T> order;

  /// Whether an icon never moves and nothing takes its place ("All").
  final bool Function(T id) fixed;

  /// [id] moved to place [to] of [order]; null where the grid cannot be
  /// reordered, so a lifted icon only opens its menu or goes back.
  final void Function(T id, {required int to})? onMove;

  /// The grid, laid out over `places`: [order] as the drag in flight shows
  /// it.
  final Widget Function(BuildContext context, {required List<T> places})
  builder;

  /// Tells the grid around [context] that a drag of [id] ended.
  static void dragEnded<T extends Object>(
    BuildContext context, {
    required T id,
  }) => context.getInheritedWidgetOfExactType<_Drag<T>>()?.grid._ended(id);

  @override
  State<LauncherGrid<T>> createState() => _LauncherGridState<T>();
}

class _LauncherGridState<T extends Object> extends State<LauncherGrid<T>> {
  /// The icon lifted and the place it hovers over, while a drag is in flight.
  ({T dragged, int at})? _hover;

  List<T> get _shown {
    final hover = _hover;
    if (hover == null || widget.onMove == null) return widget.order;
    final rest = [
      for (final id in widget.order)
        if (id != hover.dragged) id,
    ];
    if (rest.length == widget.order.length) return widget.order;
    return rest..insert(hover.at.clamp(0, rest.length), hover.dragged);
  }

  /// Whether [id] may take place [at] of the grid as it is shown.
  bool _takes(T id, {required int at, required List<T> shown}) =>
      widget.onMove != null &&
      at >= 0 &&
      at < shown.length &&
      shown[at] != id &&
      !widget.fixed(id) &&
      !widget.fixed(shown[at]);

  void _hoverAt(T dragged, {required int at}) {
    if (_hover == (dragged: dragged, at: at)) return;
    setState(() => _hover = (dragged: dragged, at: at));
    unawaited(HapticFeedback.selectionClick());
  }

  void _ended(T dragged) {
    final hover = _hover;
    if (hover == null) return;
    setState(() => _hover = null);
    final onMove = widget.onMove;
    if (onMove == null || hover.dragged != dragged) return;
    if (widget.order.indexOf(dragged) != hover.at) {
      onMove(dragged, to: hover.at);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return _Drag<T>(
      grid: this,
      shown: shown,
      child: widget.builder(context, places: shown),
    );
  }
}

class _Drag<T extends Object> extends InheritedWidget {
  const _Drag({required this.grid, required this.shown, required super.child});

  final _LauncherGridState<T> grid;
  final List<T> shown;

  @override
  bool updateShouldNotify(_Drag<T> oldWidget) => shown != oldWidget.shown;
}

/// The [index]-th place of a [LauncherGrid]. It stays where the grid lays it
/// out while icons slide, so an icon lifted over it asks for this place
/// without the grid moving under the finger; and it gives screen readers the
/// moves a drag makes.
class LauncherCell<T extends Object> extends StatelessWidget {
  const LauncherCell({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final drag = context.dependOnInheritedWidgetOfExactType<_Drag<T>>()!;
    final grid = drag.grid;
    final shown = drag.shown;
    final holds = shown[index];
    final onMove = grid.widget.onMove;
    final words = WidgetsLocalizations.of(context);
    return Semantics(
      customSemanticsActions: onMove == null
          ? null
          : {
              if (grid._takes(holds, at: index - 1, shown: shown))
                CustomSemanticsAction(label: words.reorderItemUp): () =>
                    onMove(holds, to: index - 1),
              if (grid._takes(holds, at: index + 1, shown: shown))
                CustomSemanticsAction(label: words.reorderItemDown): () =>
                    onMove(holds, to: index + 1),
            },
      child: DragTarget<T>(
        onWillAcceptWithDetails: (details) {
          if (!grid._takes(details.data, at: index, shown: shown)) {
            return false;
          }
          grid._hoverAt(details.data, at: index);
          return true;
        },
        // The icon that held this place may have slid to another while the
        // finger stayed on it, and a drag enters a target only once; asked
        // again on every move, the place follows where the finger is.
        onMove: (details) {
          if (grid._takes(details.data, at: index, shown: shown)) {
            grid._hoverAt(details.data, at: index);
          }
        },
        builder: (context, _, _) => child,
      ),
    );
  }
}
