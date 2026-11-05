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
