import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/edit_site_dialog.dart';

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

Future<SiteEdit? Function()> _open(
  WidgetTester tester,
  WebViewModel site,
) async {
  SiteEdit? result;
  var closed = false;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showEditSiteDialog(context, site);
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () {
    expect(closed, isTrue, reason: 'the dialog must have closed');
    return result;
  };
}

void main() {
  // A custom icon keeps the preview off the favicon fetch path.
  WebViewModel site() => WebViewModel(
    initUrl: 'https://example.com',
    name: 'Example',
    customIconPng: _png(),
  );

  testWidgets(
    'Save hands back the trimmed name and a schemed URL, icon untouched',
    (tester) async {
      final result = await _open(tester, site());
      await tester.enterText(
        find.widgetWithText(TextField, 'Site Name'),
        '  Renamed  ',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'URL'),
        ' example.org/path ',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final edit = result();
      expect(edit, isNotNull);
      expect(edit!.name, 'Renamed');
      expect(edit.url, 'https://example.org/path');
      expect(
        edit.icon,
        isNull,
        reason: 'an icon the user did not touch is not an edit',
      );
    },
  );

  testWidgets('resetting the icon hands back an icon edit with no bytes', (
    tester,
  ) async {
    final result = await _open(tester, site());
    await tester.tap(find.byIcon(Icons.restart_alt));
    await tester.pump();
    expect(find.byIcon(Icons.restart_alt), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final edit = result();
    expect(edit!.icon, isNotNull);
    expect(edit.icon!.png, isNull);
  });

  testWidgets('Cancel hands back nothing', (tester) async {
    final result = await _open(tester, site());
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result(), isNull);
  });
}
