import 'package:flutter/material.dart';

/// One choice as a row of icon segments at the end of a settings row, each
/// naming its value in a tooltip; a null [onChanged] disables them.
class IconSegments<T extends Object> extends StatelessWidget {
  const IconSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;

  // A segment is a TextButton whose 64pt minimum width no segmented button
  // style reaches (it copies no minimumSize); density is the one knob that
  // does, and its floor is one tap target wide, so four segments leave a
  // phone-width row its title and subtitle.
  static const _density = VisualDensity(horizontal: VisualDensity.minimumDensity);

  @override
  Widget build(BuildContext context) => SegmentedButton<T>(
        segments: segments,
        selected: {selected},
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: _density),
        onSelectionChanged: onChanged == null
            ? null
            : (selection) => onChanged!(selection.first),
      );
}
