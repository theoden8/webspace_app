import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/localized.dart';

/// Taps Clear Cookies on a site's settings and confirms it.
Future<void> _clear(WidgetTester tester,
    {required Future<void> Function() onClearCookies}) async {
  await pumpLocalized(tester,
      size: const Size(1000, 4000),
      home: SettingsScreen(
        webViewModel: WebViewModel(initUrl: 'https://example.com/'),
        useContainers: false,
        onClearCookies: onClearCookies,
      ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Clear Cookies'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Clear'));
  await tester.pumpAndSettle();
}

/// The Clear Cookies button says what the clear did once it ran: a jar that
/// refused the deletes is reported, never "Cookies cleared" (ISO-014).
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await PlatformInfo.initialize();
  });

  testWidgets(
      'ISO-014: a clear the jar refuses says so, not that cookies were '
      'cleared', (tester) async {
    await _clear(tester,
        onClearCookies: () async => throw const CookieJarFailure('refused'));

    expect(find.text('Cookie store failed: refused'), findsOneWidget);
    expect(find.text('Cookies cleared'), findsNothing);
  });

  testWidgets('ISO-014: a clear says it is done only once it is',
      (tester) async {
    final cleared = Completer<void>();
    await _clear(tester, onClearCookies: () => cleared.future);
    expect(find.text('Cookies cleared'), findsNothing);

    cleared.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cookies cleared'), findsOneWidget);
  });
}
