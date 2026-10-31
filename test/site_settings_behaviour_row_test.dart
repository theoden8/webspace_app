import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/no_shortcuts.dart';

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

String _behaviourSummary(WidgetTester tester) {
  final row = find.ancestor(
    of: find.text('Behaviour'),
    matching: find.byType(ListTile),
  );
  final tile = tester.widget<ListTile>(row);
  return (tile.subtitle! as Text).data!;
}

/// The site's Behaviour row names Kiosk mode only where a shortcut launch,
/// the one thing it decides, can happen (KIOSK-006).
void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  WebViewModel kioskSite() =>
      WebViewModel(initUrl: 'https://example.com/', kioskMode: true);

  testWidgets('the Behaviour row names a kiosk site', (tester) async {
    await _pump(tester, model: kioskSite());
    expect(_behaviourSummary(tester), contains('Kiosk mode'));
  });

  testWidgets('where no shortcut can be added, as on a TV, the Behaviour '
      'row does not name a stored kiosk (KIOSK-006)', (tester) async {
    withoutShortcuts();
    await _pump(tester, model: kioskSite());
    expect(_behaviourSummary(tester), isNot(contains('Kiosk mode')));
  });
}
