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
  final loc = AppLocalizations.of(context);
  final confirmed = await choose<bool>(
    context,
    title: title,
    body: body,
    content: content,
    options: [
      (false, cancelLabel ?? loc.commonCancel),
      (true, confirmLabel),
    ],
    destructive: destructive ? true : null,
  );
  return confirmed ?? false;
}

/// Asks the user to pick one of [options], drawn as buttons in order; null
/// when the dialog is dismissed. The option whose value is [destructive] is
/// drawn in the theme's error colour.
Future<T?> choose<T>(
  BuildContext context, {
  required String title,
  String? body,
  Widget? content,
  required List<(T?, String)> options,
  T? destructive,
}) {
  assert(body == null || content == null, 'body is content as plain text');
  final shown = content ?? (body == null ? null : Text(body));
  return showDialog<T>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: shown == null ? null : SingleChildScrollView(child: shown),
      actions: [
        for (final (value, label) in options)
          TextButton(
            onPressed: () => Navigator.pop(ctx, value),
            style: value != null && value == destructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error,
                  )
                : null,
            child: Text(label),
          ),
      ],
    ),
  );
}
