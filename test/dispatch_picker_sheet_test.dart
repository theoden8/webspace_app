import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/dispatch_picker_sheet.dart';

final _work = WebViewModel(
  siteId: 'work',
  initUrl: 'https://work.example/',
  name: 'Work GitHub',
);
final _personal = WebViewModel(
  siteId: 'personal',
  initUrl: 'https://personal.example/',
  name: 'Personal GitHub',
);
final _url = Uri.parse('https://github.com/x');

/// Opens the sheet from a button and returns a getter for what it popped.
Future<DispatchChoice? Function()> _open(
  WidgetTester tester,
  DispatchPickerSheet sheet,
) async {
  DispatchChoice? result;
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await showModalBottomSheet<DispatchChoice>(
            context: context,
            isScrollControlled: true,
            builder: (_) => sheet,
          );
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

DispatchPickerSheet _outbound() => DispatchPickerSheet(
      url: _url,
      winners: [_work, _personal],
      otherSites: const [],
      canBind: false,
      canCreate: false,
      claimDomains: false,
      outboundSourceName: 'DuckDuckGo',
    );

void main() {
  group('outbound mode (LIR-016)', () {
    testWidgets('lists the winners, the checkbox and the fallback only',
        (tester) async {
      await _open(tester, _outbound());
      expect(find.text('Open in Work GitHub'), findsOneWidget);
      expect(find.text('Open in Personal GitHub'), findsOneWidget);
      expect(
        find.text('Always use this when opening links from DuckDuckGo'),
        findsOneWidget,
      );
      expect(find.text('Open without routing'), findsOneWidget);
      expect(find.byIcon(Icons.link), findsNothing,
          reason: 'the send-or-open-to-a-site row is inbound only');
      expect(find.textContaining('Create'), findsNothing);
      final box = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
      expect(box.value, isTrue);
    });

    testWidgets('a winner pick carries the checkbox', (tester) async {
      final result = await _open(tester, _outbound());
      await tester.tap(find.text('Open in Work GitHub'));
      await tester.pumpAndSettle();
      final choice = result();
      expect(choice, isA<DispatchChoiceOpen>());
      choice as DispatchChoiceOpen;
      expect(choice.site.siteId, 'work');
      expect(choice.remember, isTrue);
    });

    testWidgets('unticking the checkbox picks without remembering',
        (tester) async {
      final result = await _open(tester, _outbound());
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in Personal GitHub'));
      await tester.pumpAndSettle();
      final choice = result() as DispatchChoiceOpen;
      expect(choice.site.siteId, 'personal');
      expect(choice.remember, isFalse);
    });

    testWidgets('open without routing', (tester) async {
      final result = await _open(tester, _outbound());
      await tester.tap(find.text('Open without routing'));
      await tester.pumpAndSettle();
      expect(result(), isA<DispatchChoiceFallback>());
    });

    testWidgets('dismissing opens nothing', (tester) async {
      final result = await _open(tester, _outbound());
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result(), isNull);
    });
  });

  testWidgets('inbound mode keeps its rows and never remembers',
      (tester) async {
    final result = await _open(
      tester,
      DispatchPickerSheet(
        url: _url,
        winners: [_work],
        otherSites: [_personal],
        canBind: true,
        canCreate: true,
        claimDomains: false,
      ),
    );
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('Open without routing'), findsNothing);
    expect(find.byIcon(Icons.link), findsOneWidget);
    await tester.tap(find.text('Open in Work GitHub'));
    await tester.pumpAndSettle();
    expect((result() as DispatchChoiceOpen).remember, isFalse);
  });
}
