// App Settings > Behaviour: the site navigation rows, each shown only where
// the chosen navigation has something for it to set.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/settings/app_prefs.dart';

import 'helpers/localized.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, {required String navigation}) async {
    await AppPref.siteNavigation.set(navigation);
    await tester.pumpWidget(
      localizedApp(
        AppBehaviourScreen(
          onOpenLinkHandlingSettings: () {},
          homeShortcuts: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Behaviour shows the rows for the chosen navigation only', (
    tester,
  ) async {
    addTearDown(() => AppPref.siteNavigation.debugValue = 'tabButton');
    final rows = [
      'In full screen',
      'Open sidebar shows',
      'Expand rail on hover',
      'Position',
      'Tab Width Limit',
    ];
    final shown = {
      'tabButton': <String>{},
      'strip': {'In full screen', 'Position', 'Tab Width Limit'},
      'sidebar': {
        'In full screen',
        'Open sidebar shows',
        'Expand rail on hover',
      },
    };
    for (final MapEntry(key: navigation, value: expected) in shown.entries) {
      await pump(tester, navigation: navigation);
      expect(find.text('Site navigation'), findsOneWidget, reason: navigation);
      for (final row in rows) {
        expect(
          find.text(row),
          expected.contains(row) ? findsOneWidget : findsNothing,
          reason: '$row with $navigation',
        );
      }
    }
  });

  testWidgets('picking Sidebar sets the navigation', (tester) async {
    addTearDown(() => AppPref.siteNavigation.debugValue = 'tabButton');
    await pump(tester, navigation: 'tabButton');
    await tester.tap(find.text('Tab button'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sidebar').last);
    await tester.pumpAndSettle();
    expect(AppPref.siteNavigation.value, 'sidebar');
  });
}
