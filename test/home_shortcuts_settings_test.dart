// HS-017: App Settings > Behaviour lists the pinned home screen shortcuts;
// tapping one points it at another site, Disable greys it out after asking.

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/screens/home_shortcuts_settings.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/shortcut_id.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/localized.dart';

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

// A custom icon keeps each row off the favicon fetch path.
WebViewModel _site({required String name, required String url}) =>
    WebViewModel(initUrl: url, name: name, customIconPng: _png());

/// Models the controller: the list it publishes, and what the screen asked.
class _FakeHost implements HomeShortcutsHost {
  _FakeHost(List<HomeShortcut> shortcuts) : homeShortcuts = ValueNotifier(shortcuts);

  @override
  final ValueNotifier<List<HomeShortcut>> homeShortcuts;

  int refreshes = 0;
  final reassigned = <ShortcutId>[];
  final disabled = <ShortcutId>[];

  @override
  Future<void> refreshHomeShortcuts() async => refreshes++;

  @override
  Future<void> reassignHomeShortcut(ShortcutId id) async => reassigned.add(id);

  @override
  Future<void> disableHomeShortcut(ShortcutId id) async {
    disabled.add(id);
    homeShortcuts.value = [
      for (final s in homeShortcuts.value)
        if (s.id != id) s,
    ];
  }
}

void main() {
  final mail = _site(name: 'Mail', url: 'https://mail.example.com');
  final news = _site(name: 'News', url: 'https://news.example.com');
  final mailTile = ShortcutId.mint();
  final newsTile = ShortcutId.mint();
  final orphanTile = ShortcutId.parse('site_gone')!;

  List<HomeShortcut> pinned() => [
        (id: mailTile, opens: mail, url: mail.initUrl),
        (id: newsTile, opens: news, url: news.initUrl),
        (id: orphanTile, opens: null, url: 'https://gone.example.com'),
      ];

  group('HomeShortcutsScreen', () {
    testWidgets('re-reads the launcher and lists each tile with its site',
        (tester) async {
      final host = _FakeHost(pinned());
      await pumpLocalized(tester, home: HomeShortcutsScreen(host: host));
      await tester.pumpAndSettle();

      expect(host.refreshes, 1);
      expect(find.text('Mail'), findsOneWidget);
      expect(find.text('https://mail.example.com'), findsOneWidget);
      expect(find.text('News'), findsOneWidget);
      expect(find.text('Deleted site'), findsOneWidget);
      expect(find.text('https://gone.example.com'), findsOneWidget,
          reason: 'a tile whose site is gone shows the address it last opened');
    });

    testWidgets('tapping a tile asks to point it elsewhere', (tester) async {
      final host = _FakeHost(pinned());
      await pumpLocalized(tester, home: HomeShortcutsScreen(host: host));
      await tester.pumpAndSettle();

      await tester.tap(find.text('News'));
      await tester.pumpAndSettle();
      expect(host.reassigned, [newsTile]);
      expect(host.disabled, isEmpty);
    });

    testWidgets('Disable asks first, and Cancel leaves the tile',
        (tester) async {
      final host = _FakeHost(pinned());
      await pumpLocalized(tester, home: HomeShortcutsScreen(host: host));
      await tester.pumpAndSettle();
      final disableMail = find.descendant(
        of: find.ancestor(of: find.text('Mail'), matching: find.byType(ListTile)),
        matching: find.byIcon(Icons.block),
      );

      await tester.tap(disableMail);
      await tester.pumpAndSettle();
      expect(find.text('Disable this shortcut?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.disabled, isEmpty);

      await tester.tap(disableMail);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Disable'),
      ));
      await tester.pumpAndSettle();
      expect(host.disabled, [mailTile]);
      expect(host.reassigned, isEmpty);
      expect(find.text('Mail'), findsNothing);
    });

    testWidgets('says how to add one when there is none', (tester) async {
      final host = _FakeHost(const []);
      await pumpLocalized(tester, home: HomeShortcutsScreen(host: host));
      await tester.pumpAndSettle();
      expect(
        find.text('No shortcuts on the home screen. Add one from a site\'s menu.'),
        findsOneWidget,
      );
    });
  });

  group('Behaviour row', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AppPref.loadAll(await SharedPreferences.getInstance());
    });

    testWidgets('counts the tiles and opens the list', (tester) async {
      final host = _FakeHost(pinned());
      await pumpLocalized(
        tester,
        home: AppBehaviourScreen(
          onOpenLinkHandlingSettings: () {},
          homeShortcuts: host,
        ),
      );
      await tester.pumpAndSettle();
      // Scroll the lazy list before checking a row below the first viewport.
      await tester.scrollUntilVisible(
        find.text('Home screen shortcuts'),
        200,
      );
      await tester.pumpAndSettle();
      expect(find.text('3 shortcuts'), findsOneWidget);

      host.homeShortcuts.value = [pinned().first];
      await tester.pumpAndSettle();
      expect(find.text('1 shortcut'), findsOneWidget);

      await tester.tap(find.text('Home screen shortcuts'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeShortcutsScreen), findsOneWidget);
    });

    testWidgets('is absent while no tile is pinned, as on a TV whose '
        'launcher takes none (HS-017, HS-004)', (tester) async {
      final host = _FakeHost(const []);
      await pumpLocalized(
        tester,
        home: AppBehaviourScreen(
          onOpenLinkHandlingSettings: () {},
          homeShortcuts: host,
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Link handling'), 200);
      await tester.pumpAndSettle();
      expect(find.text('Home screen shortcuts'), findsNothing);

      host.homeShortcuts.value = pinned();
      await tester.pumpAndSettle();
      expect(find.text('Home screen shortcuts'), findsOneWidget,
          reason: 'a tile pinned from a site\'s menu brings the row');
    });

    testWidgets('is absent where no platform lists its tiles', (tester) async {
      await pumpLocalized(
        tester,
        home: AppBehaviourScreen(
          onOpenLinkHandlingSettings: () {},
          homeShortcuts: null,
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Link handling'), 200);
      await tester.pumpAndSettle();
      expect(find.text('Home screen shortcuts'), findsNothing);
    });
  });
}
