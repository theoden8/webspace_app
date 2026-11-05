import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/app_appearance.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'helpers/localized.dart';

Future<void> _pumpAppearance(WidgetTester tester) => pumpLocalized(
  tester,
  size: const Size(400, 900),
  home: AppAppearanceScreen(
    settings: const AppThemeSettings(),
    onSettingsChanged: (_) {},
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    AppPref.legacyDesign.debugValue = AppPref.legacyDesign.fallback;
    AppPref.libraryIconSize.debugValue = AppPref.libraryIconSize.fallback;
  });

  testWidgets(
    'Appearance offers the icon size only outside Legacy design, and a drag '
    'sets every icon\'s size once let go (WEBSPACE-017)',
    (tester) async {
      AppPref.legacyDesign.debugValue = true;
      await _pumpAppearance(tester);
      expect(find.text('Icon size'), findsNothing, reason: 'Legacy design on');

      AppPref.legacyDesign.debugValue = false;
      await tester.pumpAndSettle();
      expect(find.text('Icon size'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      var writes = 0;
      void count() => writes++;
      AppPref.libraryIconSize.listenable.addListener(count);
      addTearDown(() => AppPref.libraryIconSize.listenable.removeListener(count));
      final slider = find.byType(Slider);
      await tester.drag(slider, const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(AppPref.libraryIconSize.value, LibraryStyle.iconSizeMax);
      expect(writes, 1, reason: 'set once, as the drag ends');
      expect(find.text('${LibraryStyle.iconSizeMax}%'), findsOneWidget);

      await tester.drag(slider, const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(AppPref.libraryIconSize.value, LibraryStyle.iconSizeMin);
    },
  );
}
