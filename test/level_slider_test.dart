import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/widgets/level_slider.dart';

/// Narrowest phone the app targets, at the per-site row's own indentation:
/// the tick row is the widest thing on the control and the only part of it
/// that carries a translated string.
Future<void> _pump(
  WidgetTester tester,
  List<String> labels,
  int value,
) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: LevelSlider(
        padding: const EdgeInsets.only(left: 32, right: 16),
        labels: labels,
        value: value,
        onChanged: (_) {},
      ),
    ),
  ));
}

void main() {
  testWidgets('every stop is labelled and the current one stands out',
      (tester) async {
    await _pump(tester, dnsBlockLevelNames, 2);
    for (final name in dnsBlockLevelNames) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(
      tester.widget<Text>(find.text(dnsBlockLevelNames[2])).style?.fontWeight,
      FontWeight.bold,
    );
    expect(
      tester.widget<Text>(find.text(dnsBlockLevelNames[3])).style?.fontWeight,
      FontWeight.normal,
    );
  });

  testWidgets('an out-of-range value lands on a real stop', (tester) async {
    // A site can carry a level this build no longer offers; the slider must
    // still render rather than assert its value out of the track.
    await _pump(tester, dnsBlockLevelNames, 99);
    expect(tester.takeException(), isNull);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 5.0);
  });

  testWidgets('the tick row fits a narrow phone in every locale',
      (tester) async {
    // Only the leftmost stop is translated (the level names are Hagezi's own),
    // so a long word for "app" is the one thing that can push the row over.
    for (final locale in AppLocalizations.supportedLocales) {
      final loc = await AppLocalizations.delegate.load(locale);
      await _pump(tester, [
        loc.siteSettingsDnsLevelFollowAppShort,
        for (var level = 1; level <= kDnsMaxLevel; level++)
          dnsBlockLevelNames[level],
      ], 0);
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });
}
