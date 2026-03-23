import 'package:flutter/material.dart';

/// A small info icon button that shows a descriptive tooltip dialog.
class HintButton extends StatelessWidget {
  final String title;
  final String description;

  const HintButton({
    super.key,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        Icons.info_outline,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      tooltip: title,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: () {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              child: SingleChildScrollView(
                child: Text(description),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      },
    );
  }
}
