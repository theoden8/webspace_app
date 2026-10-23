import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/widgets/launcher_grid.dart';

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
///
/// Where a remote drives the device, an icon in a launcher grid offers the
/// moves its grid makes ([LauncherCell.menuMoves]), and a move picked is
/// made here, returning null.
Future<SiteListAction?> showSiteListMenu(
  BuildContext context, {
  required Offset position,
  required bool canMoveUp,
  required bool canMoveDown,
  required bool archived,
}) async {
  final loc = AppLocalizations.of(context);
  final grid = LauncherCell.menuMoves(context);
  final action = await showLauncherMenu(
    context,
    position: position,
    items: [
      (value: SiteListAction.edit, icon: Icons.edit, label: loc.commonEdit, destructive: false),
      (value: SiteListAction.delete, icon: Icons.delete, label: loc.commonDelete, destructive: true),
      if (grid == null ? canMoveUp : grid.earlier != null)
        (value: SiteListAction.moveUp, icon: Icons.arrow_upward, label: loc.homeMoveUp, destructive: false),
      if (grid == null ? canMoveDown : grid.later != null)
        (value: SiteListAction.moveDown, icon: Icons.arrow_downward, label: loc.homeMoveDown, destructive: false),
      if (!archived)
        (value: SiteListAction.moveToArchive, icon: Icons.archive_outlined, label: loc.homeMoveToArchive, destructive: false),
      if (archived)
        (value: SiteListAction.moveOutOfArchive, icon: Icons.unarchive_outlined, label: loc.homeMoveOutOfArchive, destructive: false),
      if (archived)
        (value: SiteListAction.closeArchive, icon: Icons.lock_outline, label: loc.homeCloseArchive, destructive: false),
    ],
  );
  if (grid == null) return action;
  switch (action) {
    case SiteListAction.moveUp:
      grid.earlier?.call();
      return null;
    case SiteListAction.moveDown:
      grid.later?.call();
      return null;
    case SiteListAction.edit ||
          SiteListAction.delete ||
          SiteListAction.moveToArchive ||
          SiteListAction.moveOutOfArchive ||
          SiteListAction.closeArchive ||
          null:
      return action;
  }
}

/// One row of a launcher icon's menu.
typedef LauncherMenuItem<T> = ({
  T value,
  IconData icon,
  String label,
  bool destructive,
});

/// The menu a long press or a secondary click opens on a launcher icon, a
/// site's or a webspace's, at [position].
Future<T?> showLauncherMenu<T>(
  BuildContext context, {
  required Offset position,
  required List<LauncherMenuItem<T>> items,
}) => showMenu<T>(
  context: context,
  position: RelativeRect.fromLTRB(
      position.dx, position.dy, position.dx + 1, position.dy + 1),
  items: [
    for (final item in items)
      PopupMenuItem(
        value: item.value,
        child: ListTile(
          leading: Icon(item.icon,
              color: item.destructive ? Colors.red : null),
          title: Text(item.label,
              style: TextStyle(color: item.destructive ? Colors.red : null)),
          dense: true,
          visualDensity: VisualDensity.compact,
        ),
      ),
  ],
);
