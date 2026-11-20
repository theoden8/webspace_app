import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/add_site.dart';

import 'helpers/fake_file_picker.dart';
import 'helpers/localized.dart';

/// The Add site screen pushed over a page, as the app opens it; what it
/// pops with.
Future<List<Object?>> _open(WidgetTester tester) async {
  final popped = <Object?>[];
  await pumpLocalized(
    tester,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async => popped.add(
          await Navigator.of(context).push<Object?>(
            MaterialPageRoute<Object?>(
              builder: (_) => AddSiteScreen(
                suggestions: const [],
                onSuggestionsChanged: (_) {},
                existingUrls: const [],
              ),
            ),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

Finder get _import => find.widgetWithText(OutlinedButton, 'Import File');

void main() {
  testWidgets('the Add site screen offers an HTML import beside Add Site '
      '(IMPORT-001)', (tester) async {
    await _open(tester);
    expect(_import, findsOneWidget);
    final add = find.widgetWithText(ElevatedButton, 'Add Site');
    expect(add, findsOneWidget);
    expect(tester.getCenter(_import).dy, tester.getCenter(add).dy,
        reason: 'the two buttons share a row');
  });

  testWidgets('the picker is asked for .html and .htm files (IMPORT-002)',
      (tester) async {
    final picker = FakeFilePicker.install();
    await _open(tester);
    await tester.tap(_import);
    await tester.pumpAndSettle();
    final pick = picker.asked.single;
    expect(pick.type, FileType.custom);
    expect(pick.extensions, ['html', 'htm']);
  });

  testWidgets('a cancelled pick leaves the Add site screen as it was '
      '(IMPORT-002)', (tester) async {
    final picker = FakeFilePicker.install();
    final popped = await _open(tester);
    await tester.tap(_import);
    await tester.pumpAndSettle();
    expect(picker.asked, hasLength(1));
    expect(find.byType(AddSiteScreen), findsOneWidget);
    expect(popped, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a picked file pops as a site with its HTML', (tester) async {
    final html = Uint8List.fromList(utf8.encode('<p>hello</p>'));
    FakeFilePicker.install(
        answer: PlatformFile(name: 'my-page.html', size: html.length, bytes: html));
    final popped = await _open(tester);
    await tester.tap(_import);
    await tester.pumpAndSettle();
    expect(find.byType(AddSiteScreen), findsNothing);
    expect(popped, [
      {'url': 'file:///my-page.html', 'name': 'my-page', 'htmlContent': '<p>hello</p>'},
    ]);
  });
}
