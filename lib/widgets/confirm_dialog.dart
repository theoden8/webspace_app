import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';

/// Asks before an action. True only when the user picked [confirmLabel];
/// dismissing the dialog counts as no.
///
/// [destructive] draws the confirm button in the theme's error colour, for an
/// action that loses something the user cannot get back.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? body,
  required String confirmLabel,
  required bool destructive,
  String? cancelLabel,
}) async {
  final loc = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: body == null ? null : SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel ?? loc.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
