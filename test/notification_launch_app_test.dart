import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/webspace_page.dart' show debugWebViewStateStorageOverride;
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// A tap on a notification that starts the app reaches no tap callback: the
/// platform reports it only as how the app was launched. A cold start that
/// never asked opened on the webspace list, and the user found the site again
/// by hand.
void main() {
  final mail = WebViewModel(initUrl: 'https://mail.example.test', name: 'Mail')
    ..notificationsEnabled = true;
  final news = WebViewModel(initUrl: 'https://news.example.test', name: 'News');

  Finder inAppBar(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  testWidgets('a cold start from a notification opens its site',
      (tester) async {
    await pumpRealApp(
      tester,
      sites: [news, mail],
      launchedByNotificationFor: mail.siteId,
    );

    expect(inAppBar('Mail'), findsOneWidget);
  });

  testWidgets('a cold start from the launcher opens the webspace list',
      (tester) async {
    await pumpRealApp(tester, sites: [news, mail]);

    expect(inAppBar('Mail'), findsNothing);
    expect(find.text('All'), findsWidgets);
  });

  testWidgets('a tap on a notification while the app runs opens its site (NAV-013)',
      (tester) async {
    // On a device the activation's reads outlast the frame the tap asks for.
    debugWebViewStateStorageOverride = _SlowNavStates();
    addTearDown(() => debugWebViewStateStorageOverride = null);
    await pumpRealApp(tester, sites: [news, mail]);
    await openWebspace(tester, name: 'All');
    expect(inAppBar('News'), findsNothing);

    await tester.runAsync(() async {
      NotificationService.instance.onNotificationTapped!(news.siteId);
    });
    await settleRealApp(tester);

    expect(inAppBar('News'), findsOneWidget);
  });

  testWidgets('a tap on a notification shows the window a close hid (NOTIF-018)',
      (tester) async {
    const channel =
        MethodChannel('org.codeberg.theoden8.webspace/desktop_window');
    final asked = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      asked.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pumpRealApp(tester, sites: [news, mail]);

    await tester.runAsync(() async {
      NotificationService.instance.onNotificationTapped!(mail.siteId);
    });
    await settleRealApp(tester);

    expect(asked, contains('show'),
        reason: 'the site the tap opens is in a window the user cannot see');
    expect(inAppBar('Mail'), findsOneWidget);
  });
}

class _SlowNavStates extends InMemoryWebViewStateStorage {
  @override
  Future<Uint8List?> loadState(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return super.loadState(key);
  }
}
