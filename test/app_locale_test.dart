import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/app_locale.dart';

// The app ships 60+ locales; gen_l10n's default resolution would return
// supportedLocales.first ('af') for any unmatched device locale, showing a
// random language. resolveSupportedLocale must fall back to English instead,
// while still honoring real matches (regression for the integration tests that
// assert English UI on a CI runner whose locale does not match 'en' exactly).
void main() {
  final supported = AppLocalizations.supportedLocales;

  test('unmatched device locale falls back to English, not af', () {
    expect(resolveSupportedLocale([const Locale('xx')], supported),
        const Locale('en'));
  });

  test('null / empty preferred falls back to English', () {
    expect(resolveSupportedLocale(null, supported), const Locale('en'));
    expect(resolveSupportedLocale(const [], supported), const Locale('en'));
  });

  test('en_US resolves to en (language match)', () {
    expect(resolveSupportedLocale([const Locale('en', 'US')], supported),
        const Locale('en'));
  });

  test('exact language match wins', () {
    expect(resolveSupportedLocale([const Locale('de')], supported),
        const Locale('de'));
  });

  test('pt_BR resolves to the pt_BR variant, not bare pt', () {
    final r = resolveSupportedLocale([const Locale('pt', 'BR')], supported);
    expect(r.languageCode, 'pt');
    expect(r.countryCode, 'BR');
  });

  test('zh-Hant-TW resolves to zh_Hant via script match', () {
    final r = resolveSupportedLocale(
      [const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW')],
      supported,
    );
    expect(r.languageCode, 'zh');
    expect(r.scriptCode, 'Hant');
  });

  test('zh-Hans-CN (Simplified, unshipped script) falls back to a zh', () {
    final r = resolveSupportedLocale(
      [const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN')],
      supported,
    );
    expect(r.languageCode, 'zh');
  });

  test('first matching preferred locale is used', () {
    final r = resolveSupportedLocale(
      [const Locale('xx'), const Locale('fr'), const Locale('de')],
      supported,
    );
    expect(r, const Locale('fr'));
  });
}
