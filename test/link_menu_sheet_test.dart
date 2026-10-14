import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/link_menu_sheet.dart';
import 'helpers/localized.dart';

/// Opens the sheet from a button and returns a getter for what it popped.
Future<LinkMenuChoice? Function()> _open(
  WidgetTester tester, {
  required LinkMenuNewTab? newTab,
}) async {
  LinkMenuChoice? result;
  await pumpLocalized(tester, home: Builder(
    builder: (context) => TextButton(
      onPressed: () async {
        result = await showLinkMenu(
          context,
          url: 'https://wpewebkit.org/',
          newTab: newTab,
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
    testWidgets('$label pops $choice with the new tab row off',
        (tester) async {
      final result =
          await _open(tester, newTab: (enabled: false, note: (_) => null));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(result(), choice);
    });
  }

  testWidgets('a site without tabs gets no new tab row (TAB-012)',
      (tester) async {
    await _open(tester, newTab: null);
    expect(find.text('Open in new tab'), findsNothing);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('a site with tabs gets the row', (tester) async {
    await _open(tester, newTab: (enabled: true, note: (_) => null));
    expect(find.text('Open in new tab'), findsOneWidget);
  });
}
