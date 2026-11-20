import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

/// LANG-003. A site's settings offer System default and 30 or more
/// languages; saving a pick sets that site's language alone and lets its
/// webview go, so the next build asks for the new language.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await PlatformInfo.initialize();
  });

  late int letGoes;

  Future<void> openSettings(
    WidgetTester tester, {
    required WebViewModel site,
  }) async {
    letGoes = 0;
    await pumpLocalized(
      tester,
      size: const Size(1000, 4000),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => SettingsScreen(
                webViewModel: site,
                appTheme: WebViewTheme.system,
                letGo: () => letGoes++,
                isolation: fakeSharedJar(),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder languageField() => find.ancestor(
    of: find.text('Language'),
    matching: find.byType(DropdownButtonFormField<String?>),
  );

  testWidgets('the picker offers System default, then 30 or more languages '
      '(LANG-003)', (tester) async {
    await openSettings(
      tester,
      site: WebViewModel(initUrl: 'https://example.com/'),
    );
    final items = tester
        .widget<DropdownButton<String?>>(
          find.descendant(
            of: languageField(),
            matching: find.byType(DropdownButton<String?>),
          ),
        )
        .items!;
    expect(items.first.value, isNull, reason: 'System default comes first');
    expect((items.first.child as Text).data, 'System default');
    final codes = [for (final item in items.skip(1)) item.value];
    expect(codes, hasLength(greaterThanOrEqualTo(30)));
    expect(codes.toSet(), hasLength(codes.length), reason: 'no code twice');
    for (final code in codes) {
      expect(
        code,
        matches(RegExp(r'^[a-z]{2,3}(-[A-Z]{2})?$')),
        reason: '$code is a language tag',
      );
    }
  });

  // Under every proxy binding: on a per-site store the proxy's own update
  // lets the webview go too, which would hide a save that does not.
  for (final binding in ProxyBinding.values) {
    testWidgets('saving a language sets it on that site alone and lets its '
        'webview go, the proxy bound ${binding.name} (LANG-003)', (
      tester,
    ) async {
      ProxyManager.pinBindingForTest(binding);
      addTearDown(() => ProxyManager.pinBindingForTest(null));
      final site = WebViewModel(initUrl: 'https://example.com/a');
      final other = WebViewModel(initUrl: 'https://example.com/b');
      await openSettings(tester, site: site);

      await tester.tap(languageField());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Español').last);
      await tester.pumpAndSettle();
      expect(letGoes, 0, reason: 'nothing changes before the save');
      expect(site.language, isNull);

      await tester.tap(find.text('Save Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(site.language, 'es');
      expect(other.language, isNull, reason: 'the language is per site');
      expect(
        letGoes,
        isPositive,
        reason: 'the webview is rebuilt with the new language',
      );
      expect(site.currentUrl, 'https://example.com/a');
    });
  }

  testWidgets('System default clears a site\'s language (LANG-003)', (
    tester,
  ) async {
    final site = WebViewModel(initUrl: 'https://example.com/')..language = 'de';
    await openSettings(tester, site: site);
    await tester.tap(languageField());
    await tester.pumpAndSettle();
    await tester.tap(find.text('System default').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Settings'));
    await tester.pumpAndSettle();
    expect(site.language, isNull);
  });
}
