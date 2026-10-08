import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';

/// What the user picked in [showLinkMenu].
enum LinkMenuChoice { newTab, open, copy }

/// The sheet a long press on a link opens: the link, then open it in a new
/// tab, open it as a tap would, or copy it. [newTabNote] is what the new-tab
/// row says under itself: the site the tab would run as, or why it is off.
Future<LinkMenuChoice?> showLinkMenu(
  BuildContext context, {
  required String url,
  required bool newTabEnabled,
  required String? Function(AppLocalizations loc) newTabNote,
}) {
  final loc = AppLocalizations.of(context);
  final note = newTabNote(loc);
  return showModalBottomSheet<LinkMenuChoice>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ),
          ListTile(
            enabled: newTabEnabled,
            leading: const Icon(Icons.tab),
            title: Text(loc.tabsOpenInNewTab),
            subtitle: note == null ? null : Text(note),
            onTap: () => Navigator.of(ctx).pop(LinkMenuChoice.newTab),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(loc.commonOpen),
            onTap: () => Navigator.of(ctx).pop(LinkMenuChoice.open),
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(loc.commonCopy),
            onTap: () => Navigator.of(ctx).pop(LinkMenuChoice.copy),
          ),
        ],
      ),
    ),
  );
}
