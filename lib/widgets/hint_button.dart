import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import 'package:webspace/theme/design_tokens.dart';

import 'package:webspace/l10n/gen/localizations.dart';

/// A small info icon button that shows a descriptive tooltip dialog.
///
/// Inside a row that merges what it holds into one node (a
/// `SwitchListTile`), a screen reader cannot press the button apart from the
/// row, so the button also offers its dialog as a custom action, which the
/// merged node carries.
class HintButton extends StatelessWidget {
  final String title;
  final String description;

  const HintButton({
    super.key,
    required this.title,
    required this.description,
  });

  /// The custom action that opens the hint titled [title], for a row whose
  /// own custom actions would hide the button's.
  static MapEntry<CustomSemanticsAction, VoidCallback> action(
    BuildContext context, {
    required String title,
    required String description,
  }) => MapEntry(
    // Flutter's own "About {name}", in every locale it has.
    CustomSemanticsAction(
      label: MaterialLocalizations.of(context).aboutListTileTitle(title),
    ),
    () => _show(context, title: title, description: description),
  );

  static Future<void> _show(
    BuildContext context, {
    required String title,
    required String description,
  }) => showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        child: SingleChildScrollView(child: Text(description)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonOk),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Semantics(
          customSemanticsActions: Map.fromEntries([
            action(context, title: title, description: description),
          ]),
          child: Icon(
            Icons.info_outline,
            size: IconSizes.action,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        tooltip: title,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(
            minWidth: TapTargets.compact, minHeight: TapTargets.compact),
        onPressed: () => _show(context, title: title, description: description),
      );
}
