import 'dart:convert';

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
  testWidgets('IMPORT-001: the import button sits beside Add Site',
      (tester) async {
    await _open(tester);
    expect(_import, findsOneWidget);
    final add = find.widgetWithText(ElevatedButton, 'Add Site');
    expect(add, findsOneWidget);
    expect(
      find.ancestor(of: _import, matching: find.byType(Row)).evaluate().toSet()
          .intersection(find
              .ancestor(of: add, matching: find.byType(Row))
              .evaluate()
              .toSet()),
      isNotEmpty,
      reason: 'one row holds both buttons',
    );
  });

  testWidgets('IMPORT-002: the picker asks for .html and .htm, and a cancel '
      'leaves the screen as it was', (tester) async {
    final picker = FakeFilePicker.install();
    final popped = await _open(tester);
    await tester.tap(_import);
    await tester.pumpAndSettle();
    expect(picker.asked, hasLength(1));
    expect(picker.asked.single.type, FileType.custom);
    expect(picker.asked.single.extensions, ['html', 'htm']);
    expect(find.byType(AddSiteScreen), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(popped, isEmpty);
  });

  testWidgets('IMPORT-002: a picked file returns as a site named for it',
      (tester) async {
    final html = utf8.encode('<p>hello</p>');
    FakeFilePicker.install(
        file: PlatformFile(name: 'my-page.html', size: html.length, bytes: html));
    final popped = await _open(tester);
    await tester.tap(_import);
    await tester.pumpAndSettle();
    expect(find.byType(AddSiteScreen), findsNothing);
    expect(popped, [
      {'url': 'file:///my-page.html', 'name': 'my-page', 'htmlContent': '<p>hello</p>'},
    ]);
  });
}
