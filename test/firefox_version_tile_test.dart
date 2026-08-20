import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/l10n/gen/app_localizations_en.dart';
import 'package:webspace/widgets/firefox_version_tile.dart';

final AppLocalizationsEn en = AppLocalizationsEn();

Future<void> pumpTile(
  WidgetTester tester, {
  bool autoUpdate = false,
  bool isUpdating = false,
  VoidCallback? onUpdate,
  ValueChanged<bool>? onAutoUpdateChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: FirefoxVersionTile(
        majorVersion: 152,
        lastChecked: DateTime(2026, 8, 20, 10, 44, 3),
        isUpdating: isUpdating,
        autoUpdate: autoUpdate,
        onUpdate: onUpdate ?? () {},
        onAutoUpdateChanged: onAutoUpdateChanged ?? (_) {},
      ),
    ),
  ));
  // A running check animates forever, so settling would time out.
  isUpdating ? await tester.pump() : await tester.pumpAndSettle();
}

void main() {
  group('FirefoxVersionTile (DM-004)', () {
    testWidgets('shows the version and the last check', (tester) async {
      await pumpTile(tester);
      expect(find.text(en.appSettingsFirefoxVersionCurrent(152)),
          findsOneWidget);
      expect(
        find.text(en.appSettingsFirefoxVersionChecked('2026-08-20 10:44:03')),
        findsOneWidget,
      );
    });

    testWidgets('manual refresh and the auto switch are both reachable',
        (tester) async {
      var updates = 0;
      bool? armed;
      await pumpTile(
        tester,
        onUpdate: () => updates++,
        onAutoUpdateChanged: (v) => armed = v,
      );

      await tester.tap(find.byIcon(Icons.sync));
      expect(updates, 1);

      await tester.tap(find.byType(Switch));
      expect(armed, isTrue);
    });

    testWidgets('the switch reflects the stored setting', (tester) async {
      await pumpTile(tester, autoUpdate: true);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('a running check replaces the button with a spinner',
        (tester) async {
      await pumpTile(tester, isUpdating: true);
      expect(find.byIcon(Icons.sync), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    // The hint dialog is the only place the auto-update explanation is
    // reachable, so it has to carry both halves.
    testWidgets('the hint explains manual and automatic updates',
        (tester) async {
      await pumpTile(tester);
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();

      final dialog = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Text),
      );
      final texts =
          tester.widgetList<Text>(dialog).map((t) => t.data ?? '').join('\n');
      expect(texts, contains(en.appSettingsFirefoxVersionHint));
      expect(texts, contains(en.appSettingsFirefoxAutoUpdate));
      expect(texts, contains(en.appSettingsFirefoxAutoUpdateHint));
    });

    // The row carries a title, a hint button, a timestamp, a switch and a
    // refresh button; narrow screens and large text scales are where a Row
    // runs out of width.
    testWidgets('lays out without overflow across widths and text scales',
        (tester) async {
      final complaints = <String>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) => complaints
          .add('${details.exception}'.split('\n').first);
      addTearDown(() => FlutterError.onError = previousOnError);

      for (final width in <double>[200, 240, 280, 320, 360, 412, 480, 800]) {
        for (final scale in <double>[1.0, 1.3, 1.6, 2.0, 2.5]) {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = Size(width, 800);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: ListView(children: [
                  FirefoxVersionTile(
                    majorVersion: 152,
                    lastChecked: DateTime(2026, 8, 20, 10, 44, 3),
                    isUpdating: false,
                    autoUpdate: true,
                    onUpdate: () {},
                    onAutoUpdateChanged: (_) {},
                  ),
                ]),
              ),
            ),
          ));
          await tester.pumpAndSettle();
          expect(complaints, isEmpty,
              reason: 'width $width, text scale $scale');
        }
      }
    });
  });
}
