import 'package:flutter/material.dart';
import 'package:webspace/theme/design_tokens.dart';

/// Picks one of [values] from a row of equal-width chips, each its [face]'s
/// icon over its label, the picked one drawn in the accent.
class IconChoiceChips<T extends Object> extends StatelessWidget {
  const IconChoiceChips({
    super.key,
    required this.values,
    required this.face,
    required this.value,
    required this.onChanged,
  });

  final List<T> values;
  final ({IconData icon, String label}) Function(T value) face;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        // A label that wraps in one chip keeps the row's chips one height.
        child: IntrinsicHeight(
          child: Row(
            spacing: 8,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final v in values) Expanded(child: _chip(context, choice: v)),
            ],
          ),
        ),
      );

  Widget _chip(BuildContext context, {required T choice}) {
    final (:icon, :label) = face(choice);
    final isSelected = choice == value;
    final accentColor = Theme.of(context).colorScheme.secondary;

    return GestureDetector(
      onTap: () => onChanged(choice),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? accentColor.withValues(alpha: 0.15) : Colors.transparent,
          border: Border.all(
            color: isSelected ? accentColor : Colors.grey.shade400,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isSelected ? accentColor : null,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? accentColor : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
