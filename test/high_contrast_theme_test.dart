// The shipped app answers the OS's Increase Contrast (iOS) or High Contrast
// (GNOME) with its high contrast theme, in either brightness (A11Y-010).
// MediaQuery carries the flag from the platform's accessibility features, and
// MaterialApp picks highContrastTheme or highContrastDarkTheme only when they
// are set; left unset it falls back to the standard theme silently.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/webspace_page.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/theme/app_theme.dart';

import 'helpers/real_app.dart';

Future<ColorScheme> _schemeShown(
  WidgetTester tester, {
  required Brightness brightness,
  required bool highContrast,
}) async {
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(highContrast: highContrast);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await pumpRealApp(tester, sites: []);
  return Theme.of(tester.element(find.byType(WebSpacePage))).colorScheme;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('the OS asking for high contrast shows the high contrast '
        '${brightness.name} theme (A11Y-010)', (tester) async {
      final shown = await _schemeShown(tester,
          brightness: brightness, highContrast: true);
      final high = buildAppTheme(AccentColor.blue.color,
              brightness: brightness, contrast: ThemeContrast.high)
          .colorScheme;
      final standard =
          buildAppTheme(AccentColor.blue.color, brightness: brightness)
              .colorScheme;
      expect(high, isNot(standard), reason: 'the two themes must differ');
      expect(shown, high);
    });

    testWidgets('without it the standard ${brightness.name} theme shows '
        '(A11Y-010)', (tester) async {
      final shown = await _schemeShown(tester,
          brightness: brightness, highContrast: false);
      expect(shown,
          buildAppTheme(AccentColor.blue.color, brightness: brightness)
              .colorScheme);
    });
  }
}
