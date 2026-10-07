import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';

/// Asks before an action. True only when the user picked [confirmLabel];
/// dismissing the dialog counts as no.
///
/// [destructive] draws the confirm button in the theme's error colour, for an
/// action that loses something the user cannot get back. [content] is for a
/// body that is more than one paragraph of text.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? body,
  Widget? content,
  required String confirmLabel,
  required bool destructive,
  String? cancelLabel,
}) async {
  assert(body == null || content == null, 'body is content as plain text');
  final loc = AppLocalizations.of(context);
  final shown = content ?? (body == null ? null : Text(body));
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: shown == null ? null : SingleChildScrollView(child: shown),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel ?? loc.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
