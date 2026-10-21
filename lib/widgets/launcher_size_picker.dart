import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/launcher_item_size.dart';

/// Changes one launcher's item size using the same choices for sites and groups.
Future<LauncherItemSize?> showLauncherSizePicker(
  BuildContext context, {
  required LauncherItemSize current,
}) {
  final loc = AppLocalizations.of(context);
  return showModalBottomSheet<LauncherItemSize>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              loc.libraryItemSize,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final size in LauncherItemSize.values)
            ListTile(
              title: Text(switch (size) {
                LauncherItemSize.small => loc.libraryItemSmall,
                LauncherItemSize.medium => loc.libraryItemMedium,
                LauncherItemSize.large => loc.libraryItemLarge,
              }),
              trailing: size == current ? const Icon(Icons.check) : null,
              selected: size == current,
              onTap: () => Navigator.pop(context, size),
            ),
        ],
      ),
    ),
  );
}
