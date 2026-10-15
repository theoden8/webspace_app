import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/localized.dart';
import 'helpers/mock_cookie_manager.dart';

/// The cookie inspector writes the jar's list into the site, which is what a
/// restart restores from; each write is saved, so a cookie deleted here does
/// not come back after the app is killed. A jar that does not answer changes
/// nothing and says so (DEVTOOLS-002).
void main() {
  Future<void> openCookies(WidgetTester tester,
      {required WebViewModel site,
      required MockCookieManager jar,
      required Future<void> Function() onSave}) async {
    await pumpLocalized(tester,
        home: DevToolsScreen(
          host: WebViewModelDevToolsHost(site),
          cookieManager: jar,
          onSave: onSave,
        ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.cookie_outlined));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'DEVTOOLS-002: a refresh the jar cannot answer keeps the list, saves '
      'nothing and says so', (tester) async {
    final jar = MockCookieManager()..failing.add(JarCall.read);
    final site = WebViewModel(initUrl: 'https://example.com/')
      ..cookies = [Cookie(name: 'session', value: 'v', domain: 'example.com')];
    var saves = 0;
    await openCookies(tester, site: site, jar: jar, onSave: () async => saves++);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('Cookie store failed: read refused'), findsOneWidget);
    expect(site.cookies.map((c) => c.name), ['session']);
    expect(saves, 0);
  });

  testWidgets(
      'DEVTOOLS-002: a delete the jar refuses keeps the cookie and says so',
      (tester) async {
    final jar = MockCookieManager();
    final site = WebViewModel(initUrl: 'https://example.com/');
    await tester.runAsync(() =>
        jar.setCookie(url: Uri.parse(site.initUrl), name: 'session', value: 'v'));
    site.cookies = [...jar.all];
    var saves = 0;
    await openCookies(tester, site: site, jar: jar, onSave: () async => saves++);

    jar.refusing.add('session');
    await tester.tap(find.text('session'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Cookie store failed: session refused'), findsOneWidget);
    expect(find.text('Deleted cookie "session"'), findsNothing);
    expect(jar.all.map((c) => c.name), ['session']);
    expect(site.cookies.map((c) => c.name), ['session']);
    expect(saves, 0);
  });

  testWidgets('refreshing and deleting cookies saves the list the jar now holds',
      (tester) async {
    final jar = MockCookieManager();
    final site = WebViewModel(initUrl: 'https://example.com/');
    final saved = <List<String>>[];
    await tester.runAsync(() async {
      for (final name in ['session', 'tracker']) {
        await jar.setCookie(url: Uri.parse(site.initUrl), name: name, value: 'v');
      }
    });

    await pumpLocalized(tester,
        home: DevToolsScreen(
          host: WebViewModelDevToolsHost(site),
          cookieManager: jar,
          onSave: () async => saved.add([for (final c in site.cookies) c.name]),
        ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.cookie_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(saved, [
      ['session', 'tracker'],
    ]);

    await tester.tap(find.text('tracker'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(saved.last, ['session']);
    expect(site.cookies.map((c) => c.name), ['session']);
  });
}
