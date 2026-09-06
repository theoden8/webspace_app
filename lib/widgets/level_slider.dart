import 'package:flutter/material.dart';

/// Discrete slider over a small set of named steps, with every step's name
/// printed under the track and the current one highlighted.
///
/// Shared by the two DNS blocklist level controls (app-wide in App Settings,
/// per-site in Site Privacy) so the same choice is not made two different
/// ways in two screens.
class LevelSlider extends StatelessWidget {
  const LevelSlider({
    super.key,
    required this.labels,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  /// Step names in order; a step's index is its value.
  final List<String> labels;

  final int value;

  /// Null disables the slider.
  final ValueChanged<int>? onChanged;

  /// Fired once the drag settles, for work too expensive to run on every
  /// step the thumb passes over (a download, a write).
  final ValueChanged<int>? onChangeEnd;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final selected = Theme.of(context).colorScheme.secondary;
    final max = labels.length - 1;
    final current = value.clamp(0, max);
    return Padding(
      padding: padding,
      child: Column(
        children: [
          Slider(
            value: current.toDouble(),
            min: 0,
            max: max.toDouble(),
            divisions: max,
            label: labels[current],
            onChanged:
                onChanged == null ? null : (v) => onChanged!(v.round()),
            onChangeEnd:
                onChangeEnd == null ? null : (v) => onChangeEnd!(v.round()),
          ),
          // Six labels at their natural width overrun a narrow phone once the
          // control is indented, and one of them is translated, so each is
          // capped at its share of the row and scaled down to fit rather than
          // allowed to overflow.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i <= max; i++)
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      labels[i],
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight:
                            i == current ? FontWeight.bold : FontWeight.normal,
                        color: i == current ? selected : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
