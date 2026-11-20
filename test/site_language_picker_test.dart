import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart' show ProxyManager;
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

/// LANG-003: the site settings' language picker offers the system default
/// and every listed language, and a save stores the pick on the site and
/// lets go of its webview so the next build sends it.
void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  Future<int Function()> openSettings(
    WidgetTester tester, {
    required WebViewModel site,
  }) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var letGo = 0;
    await tester.pumpWidget(
      localizedApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  webViewModel: site,
                  appTheme: WebViewTheme.system,
                  letGo: () => letGo++,
                  isolation: fakeSharedJar(),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => letGo;
  }

  Finder picker() => find.byType(DropdownButtonFormField<String?>);

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(picker());
    await tester.pumpAndSettle();
  }

  testWidgets('LANG-003: the system default leads more than thirty languages', (
    tester,
  ) async {
    await openSettings(
      tester,
      site: WebViewModel(initUrl: 'https://example.com/'),
    );
    final field = tester.widget<DropdownButton<String?>>(
      find.descendant(
        of: picker(),
        matching: find.byType(DropdownButton<String?>),
      ),
    );
    final codes = [for (final item in field.items!) item.value];
    expect(codes.first, isNull, reason: 'the system default sends no header');
    expect(
      codes.skip(1).whereType<String>().toSet(),
      hasLength(codes.length - 1),
      reason: 'every other entry names a language once',
    );
    expect(codes.length - 1, greaterThanOrEqualTo(30));
    expect(field.value, isNull);
  });

  // Under every proxy binding: on a per-site store the proxy's own update
  // lets the webview go too, which would hide a save that does not.
  for (final binding in ProxyBinding.values) {
    testWidgets('LANG-003: saving Spanish stores es on the site and lets go of '
        'its webview, the proxy bound ${binding.name}', (tester) async {
      ProxyManager.pinBindingForTest(binding);
      addTearDown(() => ProxyManager.pinBindingForTest(null));
      final site = WebViewModel(
        initUrl: 'https://example.com/',
        language: 'en',
      );
      final other = WebViewModel(initUrl: 'https://other.example/');
      final letGo = await openSettings(tester, site: site);
      await openPicker(tester);
      await tester.tap(find.text('Español').last);
      await tester.pumpAndSettle();
      expect(site.language, 'en', reason: 'nothing lands before the save');
      expect(letGo(), 0);

      await tester.tap(find.text('Save Settings'));
      await tester.pumpAndSettle();
      expect(site.language, 'es');
      expect(other.language, isNull, reason: 'the choice is the site\'s own');
      expect(
        letGo(),
        greaterThan(0),
        reason: 'the next build sends the new Accept-Language',
      );
      expect(find.byType(SettingsScreen), findsNothing);
    });
  }

  testWidgets('LANG-003: picking the system default clears the site\'s', (
    tester,
  ) async {
    final site = WebViewModel(initUrl: 'https://example.com/', language: 'fr');
    await openSettings(tester, site: site);
    await openPicker(tester);
    await tester.tap(find.text('System default').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Settings'));
    await tester.pumpAndSettle();
    expect(site.language, isNull);
  });
}
