import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/widgets/site_editing_prompts.dart';

import 'helpers/localized.dart';
import 'helpers/no_shortcuts.dart';

/// The review a shared site's settings get before they apply names what the
/// code turns on here.
void main() {
  Future<void> openReview(
    WidgetTester tester, {
    required Map<String, dynamic> qr,
  }) async {
    await pumpLocalized(
      tester,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => unawaited(DialogSiteEditingPrompts(
              context,
              shell: ShellStore(SiteRuntime()),
            ).reviewQrSettings(qr)),
            child: const Text('Open review'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    expect(find.text('Review shared site settings'), findsOneWidget);
  }

  const kioskCode = {
    'initUrl': 'https://example.com/',
    'kioskMode': true,
    'notificationsEnabled': true,
  };

  testWidgets('a code that turns Kiosk mode on says so', (tester) async {
    await openReview(tester, qr: kioskCode);
    expect(find.text('Turns on: Notifications, Kiosk mode'), findsOneWidget);
  });

  testWidgets('where no shortcut can be added, as on a TV, the review does '
      'not name the Kiosk mode a code stores (KIOSK-006)', (tester) async {
    withoutShortcuts();
    await openReview(tester, qr: kioskCode);
    expect(find.text('Turns on: Notifications'), findsOneWidget);
  });
}
