import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/settings/site_suggestion.dart';

import 'helpers/localized.dart';

/// The Add site screen with no suggestions, recording what it hands back.
Future<List<List<SiteSuggestion>>> _open(WidgetTester tester) async {
  final handed = <List<SiteSuggestion>>[];
  await pumpLocalized(
    tester,
    home: AddSiteScreen(
      suggestions: const [],
      onSuggestionsChanged: (s) => handed.add([...s]),
      existingUrls: const [],
    ),
  );
  await tester.pump();
  await tester.tap(find.byTooltip('Add suggested site'));
  await tester.pumpAndSettle();
  return handed;
}

Finder _field(String label) =>
    find.widgetWithText(TextField, label);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  _suggestionRemoval();
  _suggestionTap();

  testWidgets(
      'SUGGEST-002: a suggestion added without a scheme is stored with https',
      (tester) async {
    final handed = await _open(tester);
    await tester.enterText(_field('Name'), 'Example');
    await tester.enterText(_field('URL'), 'example.com');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Add Suggested Site'), findsNothing);
    final [added] = handed.single;
    expect((added.name, added.url, added.domain),
        ('Example', 'https://example.com', 'example.com'));
  });

  testWidgets('SUGGEST-002: with a field empty, Add leaves the dialog open',
      (tester) async {
    final handed = await _open(tester);
    await tester.enterText(_field('URL'), 'example.com');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Add Suggested Site'), findsOneWidget);
    expect(handed, isEmpty);
  });
}

const _github = SiteSuggestion(
    name: 'GitHub', url: 'https://github.com', domain: 'github.com');

/// The Add site screen pushed over a page, as the app opens it, with
/// GitHub suggested; what it pops with and the lists it hands back.
Future<({List<Object?> popped, List<List<SiteSuggestion>> handed})> _withGithub(
    WidgetTester tester) async {
  final popped = <Object?>[];
  final handed = <List<SiteSuggestion>>[];
  await pumpLocalized(
    tester,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async => popped.add(await Navigator.of(context).push<Object?>(
          MaterialPageRoute<Object?>(
            builder: (_) => AddSiteScreen(
              suggestions: [_github],
              onSuggestionsChanged: (s) => handed.add([...s]),
              existingUrls: const [],
            ),
          ),
        )),
        child: const Text('open'),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (popped: popped, handed: handed);
}

void _suggestionRemoval() {
  testWidgets('SUGGEST-003: a long press asks, and Remove takes it off the list',
      (tester) async {
    final (popped: _, :handed) = await _withGithub(tester);
    await tester.longPress(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('Remove GitHub?'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(handed, [isEmpty]);
    expect(find.text('GitHub'), findsNothing);
  });

  testWidgets('SUGGEST-003: Cancel keeps it', (tester) async {
    final (popped: _, :handed) = await _withGithub(tester);
    await tester.longPress(find.text('GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(handed, isEmpty);
    expect(find.text('GitHub'), findsOneWidget);
  });
}

void _suggestionTap() {
  testWidgets(
      'SUGGEST-006: a tap offers the site prefilled, with incognito to toggle, '
      'and Add creates it', (tester) async {
    final (:popped, handed: _) = await _withGithub(tester);
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('Add GitHub'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'https://github.com'), findsOneWidget);
    await tester.tap(find.byTooltip('Incognito mode off'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.pumpAndSettle();

    expect(popped, [
      {'url': 'https://github.com', 'name': '', 'incognito': true},
    ]);
  });
}
