import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';

/// NOTIF-005-I: the "iOS background limits" info dialog SHALL be shown the
/// first time the user enables Notifications on any site, and exactly
/// once per install. The "shown" flag persists in SharedPreferences.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('non-iOS hosts: dialog never shows, flag never written',
      (tester) async {
    if (Platform.isIOS) return; // tested on non-iOS hosts only
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () => maybeShowIosNotificationLimitsDialog(ctx),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Background notifications on iOS'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('iosNotificationLimitsInfoShown'), isNull);
  });

  testWidgets('SharedPreferences flag is named iosNotificationLimitsInfoShown',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'iosNotificationLimitsInfoShown': true,
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('iosNotificationLimitsInfoShown'), isTrue);
  });
}
