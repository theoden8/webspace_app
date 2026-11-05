import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';

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

Finder get _paste => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

/// The camera scanner that comes first on Android and iOS is chosen from
/// `io.Platform`, which no test host reports, so only the paste path the
/// desktops take is driven here.
void main() {
  testWidgets(
    'QR-006: the URL field\'s QR icon opens the paste dialog, with no '
    'camera on this platform',
    (tester) async {
      await _open(tester);
      final icon = find.byTooltip('Add from QR code');
      expect(
        find.descendant(of: icon, matching: find.byIcon(Icons.qr_code_scanner)),
        findsOneWidget,
      );

      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(find.text('Apply settings from QR'), findsOneWidget);
    },
  );

  testWidgets(
    'QR-006: a value the codec rejects keeps the dialog open with the '
    'error under the field',
    (tester) async {
      await _open(tester);
      await tester.tap(find.byTooltip('Add from QR code'));
      await tester.pumpAndSettle();

      await tester.enterText(_paste, 'webspace://qr/site/v1/not-a-payload');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text('Not a valid WebSpace site-settings QR.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'QR-006: a valid code closes the dialog and the screen with what it '
    'decoded',
    (tester) async {
      final popped = await _open(tester);
      await tester.tap(find.byTooltip('Add from QR code'));
      await tester.pumpAndSettle();

      final shared = {'initUrl': 'https://shared.example/', 'name': 'Shared'};
      await tester.enterText(_paste, SiteSettingsQrCodec.encode(shared));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(AddSiteScreen), findsNothing);
      expect(popped, [
        {
          'qrSettings': SiteSettingsQrCodec.decode(
            SiteSettingsQrCodec.encode(shared),
          ),
        },
      ]);
    },
  );
}
