import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/settings/shortcut_id.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/confirm_dialog.dart';

/// A pinned home screen tile as the list shows it: the site a tap opens, or
/// null when none does, and the address the tile last opened.
typedef HomeShortcut = ({ShortcutId id, WebViewModel? opens, String? url});

/// What the list asks of whoever owns the tiles (`ShortcutController`).
abstract interface class HomeShortcutsHost {
  ValueListenable<List<HomeShortcut>> get homeShortcuts;

  /// Re-reads the launcher: a pin or a removal happens outside the app.
  Future<void> refreshHomeShortcuts();

  /// Asks for a site and points [id] at it.
  Future<void> reassignHomeShortcut(ShortcutId id);

  Future<void> disableHomeShortcut(ShortcutId id);
}

/// HS-017: every enabled home screen shortcut, the site each opens, and what
/// can be done to it. Android only: no other platform lists its tiles.
class HomeShortcutsScreen extends StatefulWidget {
  const HomeShortcutsScreen({super.key, required this.host});

  final HomeShortcutsHost host;

  @override
  State<HomeShortcutsScreen> createState() => _HomeShortcutsScreenState();
}

class _HomeShortcutsScreenState extends State<HomeShortcutsScreen> {
  final _guard = ReentryGuard();

  @override
  void initState() {
    super.initState();
    unawaited(widget.host.refreshHomeShortcuts());
  }

  Future<void> _reassign(HomeShortcut shortcut) async {
    await _guard.run(() => widget.host.reassignHomeShortcut(shortcut.id));
  }

  Future<void> _disable(HomeShortcut shortcut) async {
    await _guard.run(() async {
      final loc = AppLocalizations.of(context);
      final confirmed = await confirm(
        context,
        title: loc.homeShortcutsDisableTitle,
        body: loc.homeShortcutsDisableBody,
        confirmLabel: loc.homeShortcutDisable,
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      await widget.host.disableHomeShortcut(shortcut.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.homeShortcutsTitle)),
      body: ValueListenableBuilder<List<HomeShortcut>>(
        valueListenable: widget.host.homeShortcuts,
        builder: (context, shortcuts, _) => shortcuts.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.xl),
                  child: Text(
                    loc.homeShortcutsEmpty,
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                children: [
                  for (final shortcut in shortcuts)
                    _row(shortcut, loc: loc),
                ],
              ),
      ),
    );
  }

  Widget _row(HomeShortcut shortcut, {required AppLocalizations loc}) {
    final site = shortcut.opens;
    final address = site?.initUrl ?? shortcut.url;
    return ListTile(
      leading: SizedBox.square(
        dimension: TapTargets.compact,
        child: site == null
            ? const Icon(Icons.link_off)
            : UnifiedFaviconImage.site(site, size: TapTargets.compact),
      ),
      title: Text(
        site?.getDisplayName() ?? loc.homeShortcutsSiteGone,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: address == null
          ? null
          : Text(address, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => unawaited(_reassign(shortcut)),
      trailing: IconButton(
        icon: const Icon(Icons.block),
        tooltip: loc.homeShortcutDisable,
        onPressed: () => unawaited(_disable(shortcut)),
      ),
    );
  }
}
