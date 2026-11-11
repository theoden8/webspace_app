import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/site_field.dart';
import 'package:webspace/widgets/site_editing_prompts.dart';

import 'helpers/localized.dart';
import 'helpers/no_shortcuts.dart';

/// The review a shared site's settings get before they apply names what the
/// code turns on here.
void main() {
  late final AppLocalizations en;
  setUpAll(() async =>
      en = await AppLocalizations.delegate.load(const Locale('en')));

  // The review's weakened/granted lists iterate SiteField.review, so a newly
  // carried protection toggle cannot disable a protection the dialog leaves
  // unnamed (QR-008, SEC: "review parses looser than apply"). This holds the
  // marked set and the label map to each other.
  test('every reviewed SiteField is QR-carried and has a review label (QR-008)',
      () {
    final labels = qrReviewLabels(en);
    for (final f in SiteField.values) {
      if (f.review == QrReview.none) continue;
      expect(f.qr, QrShare.carried,
          reason: '${f.name} is reviewed but not QR-carried');
      expect(labels[f], isNotNull,
          reason: '${f.name} is reviewed but has no label');
      expect(labels[f], isNotEmpty);
    }
    for (final f in labels.keys) {
      expect(f.review, isNot(QrReview.none),
          reason: '${f.name} is labeled but not marked reviewed');
    }
  });
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

  testWidgets('a code that disables HTTPS upgrade and Lockdown Mode says so '
      '(QR-008)', (tester) async {
    // A share could pair trackingProtectionEnabled:false (which a user may
    // accept, since aggressive blocking breaks sites) with the then-effective
    // httpsUpgradeEnabled:false, downgrading the site to cleartext, and
    // lockdownModeEnabled:false, disabling WebKit Lockdown Mode. Both must be
    // named, not hidden behind "Tracking Protection".
    await openReview(tester, qr: const {
      'initUrl': 'https://example.com/',
      'trackingProtectionEnabled': false,
      'httpsUpgradeEnabled': false,
      'lockdownModeEnabled': false,
    });
    expect(
        find.text('Turns off: HTTPS upgrade, Tracking Protection, '
            'Lockdown Mode'),
        findsOneWidget);
  });
}
