// Editors with a Save button guard unsaved edits like the site settings
// screen (EDIT-009, BUG-006). The user script editor and the webspace editor
// once popped on back and dropped what had been typed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  final navigator = GlobalKey<NavigatorState>();
  late Future<Object?> result;

  Future<void> open(WidgetTester tester, Widget editor) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    ));
    result = navigator.currentState!
        .push<Object?>(MaterialPageRoute(builder: (_) => editor));
    await tester.pumpAndSettle();
  }

  bool isOpen<T extends Widget>() => find.byType(T).evaluate().isNotEmpty;

  Future<void> back(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  group('user script editor', () {
    final script = UserScriptConfig(name: 'Dark', source: 'document.body;');

    testWidgets('back leaves an untouched editor at once', (tester) async {
      await open(tester, UserScriptEditScreen(script: script));
      await back(tester);

      expect(find.text('Discard changes?'), findsNothing);
      expect(isOpen<UserScriptEditScreen>(), isFalse);
    });

    testWidgets('an unsaved edit asks first, and Keep editing keeps it',
        (tester) async {
      await open(tester, const UserScriptEditScreen());
      await tester.enterText(find.byType(TextField).first, 'Half-written');
      await tester.pump();

      await back(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(isOpen<UserScriptEditScreen>(), isTrue);
      expect(find.text('Half-written'), findsOneWidget);

      await back(tester);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(isOpen<UserScriptEditScreen>(), isFalse);
      expect(await result, isNull, reason: 'discarding saves nothing');
    });

    testWidgets('an edit to the injection time alone is guarded',
        (tester) async {
      await open(tester, UserScriptEditScreen(script: script));
      await tester.tap(
          find.byType(DropdownButtonFormField<UserScriptInjectionTime>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Document start').last);
      await tester.pumpAndSettle();

      await back(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
    });
  });

  group('webspace editor', () {
    Widget editor() => WebspaceDetailScreen(
          webspace: Webspace(name: 'Work'),
          allSites: const [],
          onSave: (_) {},
        );

    testWidgets('back leaves an untouched editor at once', (tester) async {
      await open(tester, editor());
      await back(tester);
      expect(isOpen<WebspaceDetailScreen>(), isFalse);
    });

    testWidgets('a renamed webspace asks before the name is dropped',
        (tester) async {
      await open(tester, editor());
      await tester.enterText(find.byType(TextField), 'Home');
      await tester.pump();

      await back(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(isOpen<WebspaceDetailScreen>(), isFalse);
    });
  });
}
