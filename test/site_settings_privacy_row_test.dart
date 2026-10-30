import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/site_privacy.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';

Future<void> _pump(WidgetTester tester, {required WebViewModel model}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SettingsScreen(
        webViewModel: model,
        appTheme: WebViewTheme.system,
        isolation: fakeSharedJar()),
  ));
  await tester.pumpAndSettle();
}

String _privacySummary(WidgetTester tester) {
  final row = find.ancestor(
    of: find.text('Privacy'),
    matching: find.byType(ListTile),
  );
  final tile = tester.widget<ListTile>(row);
  return (tile.subtitle! as Text).data!;
}

/// The JavaScript switch lives on the Privacy screen, and the Privacy row
/// names it among the protections that are on (ETP-017).
void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('site settings carry no JavaScript switch of their own',
      (tester) async {
    await _pump(tester, model: WebViewModel(initUrl: 'https://example.com/'));
    expect(find.text('JavaScript Enabled'), findsNothing);
  });

  testWidgets('the Privacy row leads with JavaScript off (ETP-017)',
      (tester) async {
    await _pump(tester,
        model: WebViewModel(
            initUrl: 'https://example.com/',
            trackingProtectionEnabled: false,
            javascriptEnabled: false));
    expect(_privacySummary(tester), startsWith('JavaScript off · '),
        reason: 'the blockers a new site has on must not push it into the '
            'overflow');
  });

  testWidgets('the umbrella line does not stand for JavaScript off',
      (tester) async {
    await _pump(tester,
        model: WebViewModel(
            initUrl: 'https://example.com/', javascriptEnabled: false));
    expect(_privacySummary(tester), 'JavaScript off · Tracking Protection on');
  });

  testWidgets('a switch flipped on the Privacy screen reaches the row',
      (tester) async {
    await _pump(tester, model: WebViewModel(initUrl: 'https://example.com/'));
    expect(_privacySummary(tester), 'Tracking Protection on');
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.byType(SitePrivacyScreen), findsOneWidget);
    await tester.tap(find.text('JavaScript Enabled'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_privacySummary(tester), 'JavaScript off · Tracking Protection on');
  });
}
