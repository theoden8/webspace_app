import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';

/// NOTIF-005-{I,A}: the background-limits info dialog SHALL be shown the
/// first time the user enables Notifications on any site (on iOS or
/// Android), and exactly once per install. The "shown" flag persists in
/// SharedPreferences under `bgNotificationLimitsInfoShown`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('non-mobile hosts: dialog never shows, flag never written',
      (tester) async {
    if (Platform.isIOS || Platform.isAndroid) return;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () =>
              maybeShowBackgroundNotificationLimitsDialog(ctx),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Background notifications on iOS'), findsNothing);
    expect(find.text('Background notifications on Android'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('bgNotificationLimitsInfoShown'), isNull);
  });

  testWidgets('SharedPreferences flag is named bgNotificationLimitsInfoShown',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'bgNotificationLimitsInfoShown': true,
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('bgNotificationLimitsInfoShown'), isTrue);
  });
}
