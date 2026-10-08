import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';

/// What a site's long-press menu in the list offers.
enum SiteListAction {
  edit,
  delete,
  moveUp,
  moveDown,
  moveToArchive,
  moveOutOfArchive,
  closeArchive,
}

/// The menu a long press on a site in the list opens at [position]. An
/// app-tier site always offers "Move to archive", whether or not an archive is
/// open: the move prompts for a passphrase and opens or creates the archive
/// it names, so the row reveals nothing about which archives exist.
Future<SiteListAction?> showSiteListMenu(
  BuildContext context, {
  required Offset position,
  required bool canMoveUp,
  required bool canMoveDown,
  required bool archived,
}) {
  final loc = AppLocalizations.of(context);
  PopupMenuItem<SiteListAction> item(
    SiteListAction action, {
    required IconData icon,
    required String label,
    Color? color,
  }) =>
      PopupMenuItem(
        value: action,
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(label, style: TextStyle(color: color)),
          dense: true,
          visualDensity: VisualDensity.compact,
        ),
      );
  return showMenu<SiteListAction>(
    context: context,
    position: RelativeRect.fromLTRB(
        position.dx, position.dy, position.dx + 1, position.dy + 1),
    items: [
      item(SiteListAction.edit, icon: Icons.edit, label: loc.commonEdit),
      item(SiteListAction.delete,
          icon: Icons.delete, label: loc.commonDelete, color: Colors.red),
      if (canMoveUp)
        item(SiteListAction.moveUp,
            icon: Icons.arrow_upward, label: loc.homeMoveUp),
      if (canMoveDown)
        item(SiteListAction.moveDown,
            icon: Icons.arrow_downward, label: loc.homeMoveDown),
      if (!archived)
        item(SiteListAction.moveToArchive,
            icon: Icons.archive_outlined, label: loc.homeMoveToArchive),
      if (archived)
        item(SiteListAction.moveOutOfArchive,
            icon: Icons.unarchive_outlined, label: loc.homeMoveOutOfArchive),
      if (archived)
        item(SiteListAction.closeArchive,
            icon: Icons.lock_outline, label: loc.homeCloseArchive),
    ],
  );
}
