import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';

/// A MaterialApp around [home] wired for AppLocalizations, without which
/// `AppLocalizations.of(context)` is null in a migrated widget.
Widget localizedApp(Widget home, {ThemeData? theme, Locale? locale}) =>
    MaterialApp(
      theme: theme,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// Pumps [localizedApp]; [size] sets the view to that many logical pixels
/// for the rest of the test.
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget home, {
  ThemeData? theme,
  Locale? locale,
  Size? size,
}) async {
  if (size != null) setViewSize(tester, size);
  await tester.pumpWidget(localizedApp(home, theme: theme, locale: locale));
}

void setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
