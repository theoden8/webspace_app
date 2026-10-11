import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/localized.dart';
import 'helpers/mock_cookie_manager.dart';

/// The cookie inspector writes the jar's list into the site, which is what a
/// restart restores from; each write is saved, so a cookie deleted here does
/// not come back after the app is killed.
void main() {
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
