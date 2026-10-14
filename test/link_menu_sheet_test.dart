import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/link_menu_sheet.dart';
import 'helpers/localized.dart';

/// Opens the sheet from a button and returns a getter for what it popped.
Future<LinkMenuChoice? Function()> _open(
  WidgetTester tester, {
  required bool newTabEnabled,
}) async {
  LinkMenuChoice? result;
  await pumpLocalized(tester, home: Builder(
    builder: (context) => TextButton(
      onPressed: () async {
        result = await showLinkMenu(
          context,
          url: 'https://wpewebkit.org/',
          newTabEnabled: newTabEnabled,
          newTabNote: (_) => null,
        );
      },
      child: const Text('open'),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

void main() {
  for (final (label, choice) in [
    ('Open', LinkMenuChoice.open),
    ('Copy', LinkMenuChoice.copy),
    ('Share', LinkMenuChoice.share),
  ]) {
    testWidgets('$label pops $choice even with new tab off', (tester) async {
      final result = await _open(tester, newTabEnabled: false);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(result(), choice);
    });
  }
}
