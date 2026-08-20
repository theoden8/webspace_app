import 'package:flutter/material.dart';

import 'package:webspace/theme/design_tokens.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';

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
        size: IconSizes.action,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      tooltip: title,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: TapTargets.compact, minHeight: TapTargets.compact),
      onPressed: () {
        showDialog(
          context: context,
          builder: (context) {
            final loc = AppLocalizations.of(context);
            return AlertDialog(
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
                child: Text(loc.commonOk),
              ),
            ],
            );
          },
        );
      },
    );
  }
}
