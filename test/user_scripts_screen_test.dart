import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/runtime/arb_messages.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/settings/user_script.dart';

import 'helpers/localized.dart';

/// US-003: the User Scripts screen in its two modes, per site and the
/// global library, as each reports what the user changed.
void main() {
  late List<List<String>> saved;
  late List<List<String>> globalsSaved;
  late List<Set<UserScriptId>> optIns;
  late int resets;

  setUp(() {
    saved = [];
    globalsSaved = [];
    optIns = [];
    resets = 0;
  });

  UserScriptConfig script(String name, {bool enabled = true}) =>
      UserScriptConfig(name: name, source: '/* $name */', enabled: enabled);

  Future<void> pumpPerSite(
    WidgetTester tester, {
    required List<UserScriptConfig> site,
    List<UserScriptConfig> globals = const [],
    Set<UserScriptId> optedIn = const {},
  }) async {
    await pumpLocalized(tester,
        size: const Size(800, 1600),
        home: UserScriptsScreen(
          title: const Localized.verbatim('Scripts'),
          userScripts: site,
          onSave: (s) => saved.add([for (final x in s) '${x.name}:${x.enabled}']),
          globalUserScripts: globals,
          onGlobalUserScriptsChanged: (g) =>
              globalsSaved.add([for (final x in g) x.name]),
          enabledGlobalScriptIds: optedIn,
          onEnabledGlobalScriptIdsChanged: (ids) => optIns.add({...ids}),
          onWebViewReset: () => resets++,
          proxy: OutboundProxy.app,
        ));
    await tester.pumpAndSettle();
  }

  Finder tileOf(String name) =>
      find.ancestor(of: find.text(name), matching: find.byType(ListTile));

  Switch switchOf(WidgetTester tester, {required String name}) => tester.widget<Switch>(
      find.descendant(of: tileOf(name), matching: find.byType(Switch)));

  Future<void> swipeAway(WidgetTester tester, {required String name}) async {
    await tester.drag(tileOf(name), const Offset(-600, 0));
    await tester.pumpAndSettle();
  }

  group('per site', () {
    testWidgets('US-003: globals lead with their badge and an opt-in '
        'switch, the site\'s own follow', (tester) async {
      final g = script('Dark reader');
      await pumpPerSite(tester, site: [script('Mine')], globals: [g]);

      expect(find.descendant(of: tileOf('Dark reader'), matching: find.text('Global')),
          findsOneWidget);
      expect(find.descendant(of: tileOf('Dark reader'), matching: find.byIcon(Icons.public)),
          findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      expect(tester.getTopLeft(tileOf('Dark reader')).dy,
          lessThan(tester.getTopLeft(tileOf('Mine')).dy));
      expect(find.descendant(of: tileOf('Mine'), matching: find.text('Global')),
          findsNothing);

      expect(switchOf(tester, name: 'Dark reader').value, isFalse);
      switchOf(tester, name: 'Dark reader').onChanged!(true);
      await tester.pump();
      expect(optIns.last, {g.id});
      switchOf(tester, name: 'Dark reader').onChanged!(false);
      await tester.pump();
      expect(optIns.last, isEmpty);
      expect(globalsSaved, isEmpty, reason: 'an opt-in is the site\'s own');
    });

    testWidgets('US-003: a site script\'s switch turns it off without the '
        'editor', (tester) async {
      await pumpPerSite(tester, site: [script('Mine')]);
      switchOf(tester, name: 'Mine').onChanged!(false);
      await tester.pumpAndSettle();
      expect(saved.last, ['Mine:false']);
      expect(find.byType(UserScriptEditScreen), findsNothing);
      expect(resets, 1, reason: 'the webview is rebuilt with the change');
    });

    testWidgets('US-003: a swipe asks first; Cancel keeps the script, '
        'Delete removes it', (tester) async {
      await pumpPerSite(tester, site: [script('Keep'), script('Drop')]);

      await swipeAway(tester, name: 'Drop');
      expect(find.text('Delete "Drop"?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Drop'), findsOneWidget);
      expect(saved, isEmpty);

      await swipeAway(tester, name: 'Drop');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Delete')));
      await tester.pumpAndSettle();
      expect(find.text('Drop'), findsNothing);
      expect(saved.last, ['Keep:true']);
    });

    testWidgets('US-003: a long press offers Delete and Make Global; Make '
        'Global moves it and keeps it running here', (tester) async {
      final mine = script('Mine');
      await pumpPerSite(tester, site: [mine, script('Other')]);

      await tester.longPress(find.text('Mine'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Make Global'));
      await tester.pumpAndSettle();
      await tester.tap(find
          .descendant(
              of: find.byType(AlertDialog), matching: find.text('Make Global'))
          .last);
      await tester.pumpAndSettle();

      expect(saved.last, ['Other:true']);
      expect(globalsSaved.last, ['Mine']);
      expect(optIns.last, {mine.id});
      expect(find.descendant(of: tileOf('Mine'), matching: find.text('Global')),
          findsOneWidget);
    });

    testWidgets('US-003: a global deleted here goes from every site, after '
        'a warning that says so', (tester) async {
      final g = script('Everywhere');
      await pumpPerSite(tester, site: [script('Mine')], globals: [g],
          optedIn: {g.id});

      await tester.longPress(find.text('Everywhere'));
      await tester.pumpAndSettle();
      expect(find.text('Removes from all sites'), findsOneWidget);
      expect(find.text('Make Global'), findsNothing);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete "Everywhere" from all sites?'), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Delete')));
      await tester.pumpAndSettle();

      expect(globalsSaved.last, isEmpty);
      expect(optIns.last, isEmpty);
      expect(find.text('Everywhere'), findsNothing);
    });

    testWidgets('US-003: + opens an empty editor, a tap opens the script '
        'filled in', (tester) async {
      await pumpPerSite(tester,
          site: [UserScriptConfig(name: 'Mine', source: 'run();')]);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('New Script'), findsOneWidget);
      expect(find.text('Injection time'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Script'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Mine'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'run();'), findsOneWidget);
    });

    testWidgets('US-003: the drag handle reorders the site\'s scripts',
        (tester) async {
      await pumpPerSite(tester, site: [script('First'), script('Second')]);
      final handle = find.descendant(
          of: tileOf('First'), matching: find.byIcon(Icons.drag_handle));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, 15));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(saved.last, ['Second:true', 'First:true']);
    });
  });

  testWidgets('US-003: the global library badges every tile and offers no '
      'switch', (tester) async {
    await pumpLocalized(tester,
        size: const Size(800, 1600),
        home: UserScriptsScreen(
          title: const Localized.verbatim('Global scripts'),
          userScripts: [script('One'), script('Two')],
          onSave: (s) => saved.add([for (final x in s) x.name]),
          isGlobalLibrary: true,
          proxy: OutboundProxy.app,
        ));
    await tester.pumpAndSettle();

    expect(find.text('Global'), findsNWidgets(2));
    expect(find.byType(Switch), findsNothing);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
    await tester.longPress(find.text('One'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing,
        reason: 'no sheet: deletion is by swipe here');
  });
}
