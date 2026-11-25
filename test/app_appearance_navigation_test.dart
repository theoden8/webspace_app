// App Settings > Appearance: the sidebar's and the site strip's settings, in
// groups of their own rather than a choice (TAB-038), and the one switch for
// full screen; Behaviour keeps none of them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/app_appearance.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/site_navigation.dart';
import 'package:webspace/theme/app_theme.dart';

import 'helpers/localized.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppPref.fullscreenNavigation.debugValue =
      AppPref.fullscreenNavigation.fallback);

  Future<void> appearance(WidgetTester tester) async {
    await pumpLocalized(
      tester,
      size: const Size(400, 1600),
      home: AppAppearanceScreen(
        settings: const AppThemeSettings(),
        onSettingsChanged: (_) {},
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('APPSET-005 Appearance has the sidebar and the site strip as '
      'groups, not a choice, and Behaviour has neither', (tester) async {
    await appearance(tester);
    for (final row in [
      'Button in full screen',
      'Site strip',
      'Position',
      'Tab Width Limit',
    ]) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    expect(find.text('Site navigation'), findsNothing);
    expect(find.text('Open sidebar shows'), findsNothing,
        reason: 'the sidebar switches its own view (TAB-034)');

    await pumpLocalized(
      tester,
      size: const Size(400, 1600),
      home: AppBehaviourScreen(
        onOpenLinkHandlingSettings: () {},
        homeShortcuts: null,
      ),
    );
    await tester.pumpAndSettle();
    for (final row in [
      'Site navigation',
      'In full screen',
      'Position',
      'Tab Width Limit',
      'Expand rail on hover',
    ]) {
      expect(find.text(row), findsNothing, reason: row);
    }
  });

  testWidgets('FS-007 the Button in full screen switch sets whether full '
      'screen leaves the control', (tester) async {
    await appearance(tester);
    expect(currentFullscreenNavigation, FullscreenNavigation.button,
        reason: 'on by default');
    await tester.tap(find.text('Button in full screen'));
    await tester.pumpAndSettle();
    expect(currentFullscreenNavigation, FullscreenNavigation.hidden);
    await tester.tap(find.text('Button in full screen'));
    await tester.pumpAndSettle();
    expect(currentFullscreenNavigation, FullscreenNavigation.button);
  });
}
