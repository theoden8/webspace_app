import 'package:webspace/settings/site_ids.dart';

/// What a press in the desktop tray asks for (NOTIF-019).
sealed class TrayAction {
  const TrayAction();
}

/// The window, shown and in front.
final class TrayShow extends TrayAction {
  const TrayShow();
}

/// [site] on screen, as a tap on its notification opens it.
final class TrayOpenSite extends TrayAction {
  const TrayOpenSite(this.site);

  final SiteId site;
}

/// The app quits, where a close of its window only hides it.
final class TrayQuit extends TrayAction {
  const TrayQuit();
}

/// One line of the tray's menu. Its [id] names the same line for as long as
/// the app runs, so a press on a menu the desktop read before a change still
/// means what that menu said.
sealed class TrayEntry {
  const TrayEntry({required this.id});

  final int id;
}

final class TrayItem extends TrayEntry {
  const TrayItem({required super.id, required this.label, required this.action});

  final String label;
  final TrayAction action;
}

final class TraySeparator extends TrayEntry {
  const TraySeparator({required super.id});
}

/// What the tray shows: its name, and the menu its icon opens.
final class TrayMenu {
  TrayMenu._({required this.title, required this.entries})
      : assert(
          entries.map((e) => e.id).toSet().length == entries.length,
          'an id names one line',
        );

  final String title;
  final List<TrayEntry> entries;

  /// What a press on line [id] asks for; null for a line this menu does not
  /// hold, a site gone since the desktop read the menu among them.
  TrayAction? actionOf(int id) {
    for (final entry in entries) {
      if (entry case TrayItem(id: final i, :final action) when i == id) {
        return action;
      }
    }
    return null;
  }
}

/// The tray's own words, in the app's language.
typedef TrayLabels = ({String title, String show, String quit});

/// A site the tray lists: one with notifications on, by its name and the
/// unread count its page's title shows, null where it shows none or no page
/// runs.
typedef TraySite = ({SiteId id, String name, int? unread});

/// Builds the tray's menu, numbering each line once (NOTIF-019).
class TrayMenus {
  // dbusmenu's root is 0.
  static const _show = 1;
  static const _sitesSeparator = 2;
  static const _quitSeparator = 3;
  static const _quit = 4;

  final _siteIds = <SiteId, int>{};
  var _next = _quit + 1;

  TrayMenu build({required List<TraySite> sites, required TrayLabels labels}) =>
      TrayMenu._(title: labels.title, entries: [
        TrayItem(id: _show, label: labels.show, action: const TrayShow()),
        if (sites.isNotEmpty) const TraySeparator(id: _sitesSeparator),
        for (final site in sites)
          TrayItem(
            id: _siteIds[site.id] ??= _next++,
            label: switch (site.unread) {
              null || 0 => site.name,
              final unread => '${site.name} ($unread)',
            },
            action: TrayOpenSite(site.id),
          ),
        const TraySeparator(id: _quitSeparator),
        TrayItem(id: _quit, label: labels.quit, action: const TrayQuit()),
      ]);
}
