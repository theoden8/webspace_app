import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/tray_menu_engine.dart';
import 'package:webspace/settings/site_ids.dart';

/// NOTIF-019: what the desktop tray's menu holds, and what a press on each of
/// its lines asks for, whichever menu the desktop read.
void main() {
  const labels = (title: 'WebSpace', show: 'Show WebSpace', quit: 'Quit WebSpace');
  final chat = SiteId('chat');
  final mail = SiteId('mail');

  List<String> lines(TrayMenu menu) => [
        for (final entry in menu.entries)
          switch (entry) {
            TrayItem(:final label) => label,
            TraySeparator() => '-',
          },
      ];

  test('NOTIF-019 the menu shows the window, lists each notifying site with '
      'its unread count, and quits', () {
    final menu = TrayMenus().build(labels: labels, sites: [
      (id: chat, name: 'Chat', unread: 3),
      (id: mail, name: 'Mail', unread: null),
    ]);

    expect(lines(menu),
        ['Show WebSpace', '-', 'Chat (3)', 'Mail', '-', 'Quit WebSpace']);
    expect(menu.title, 'WebSpace');
  });

  test('a count of none reads as a site with nothing unread', () {
    final menu = TrayMenus()
        .build(labels: labels, sites: [(id: chat, name: 'Chat', unread: 0)]);
    expect(lines(menu), contains('Chat'));
  });

  test('with no notifying site the menu holds the window and quitting', () {
    final menu = TrayMenus().build(labels: labels, sites: const []);
    expect(lines(menu), ['Show WebSpace', '-', 'Quit WebSpace']);
  });

  test('NOTIF-019 each line asks for what it says', () {
    final menu = TrayMenus()
        .build(labels: labels, sites: [(id: chat, name: 'Chat', unread: 1)]);
    final actions = {
      for (final entry in menu.entries)
        if (entry case TrayItem(:final id, :final label)) label: menu.actionOf(id),
    };

    expect(actions['Show WebSpace'], isA<TrayShow>());
    expect(actions['Quit WebSpace'], isA<TrayQuit>());
    expect(actions['Chat (1)'],
        isA<TrayOpenSite>().having((a) => a.site, 'site', chat));
    for (final entry in menu.entries.whereType<TraySeparator>()) {
      expect(menu.actionOf(entry.id), isNull, reason: 'a separator does nothing');
    }
  });

  test('NOTIF-019 a site keeps its line id as the menu changes, so a press '
      'on a menu read before the change opens the site it named', () {
    final menus = TrayMenus();
    final before = menus.build(labels: labels, sites: [
      (id: chat, name: 'Chat', unread: null),
      (id: mail, name: 'Mail', unread: null),
    ]);
    final mailLine = before.entries
        .whereType<TrayItem>()
        .firstWhere((e) => e.label == 'Mail')
        .id;

    // Chat turned its notifications off; Mail moved up.
    final after = menus.build(labels: labels, sites: [
      (id: mail, name: 'Mail', unread: 2),
    ]);

    expect(after.actionOf(mailLine),
        isA<TrayOpenSite>().having((a) => a.site, 'site', mail));
    final chatLine = before.entries
        .whereType<TrayItem>()
        .firstWhere((e) => e.label == 'Chat')
        .id;
    expect(after.actionOf(chatLine), isNull,
        reason: 'a site that left the menu opens nothing');
  });
}
