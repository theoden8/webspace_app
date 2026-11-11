import 'package:flutter/material.dart' show Brightness, ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';

/// The app's theme set to [mode], as App Settings and a launch set it.
void _appTheme(ThemeMode mode) =>
    ShellStore(SiteRuntime()).theme = AppThemeSettings(themeMode: mode);

void main() {
  tearDown(() => WebViewModel.appTheme = WebViewTheme.light);

  test('a glyph the font lacks comes from the colour emoji font first, in either brightness', () {
    for (final brightness in Brightness.values) {
      final text = buildAppTheme(accentBlue, brightness: brightness).textTheme;
      for (final style in [text.bodyMedium, text.bodyLarge, text.titleMedium, text.labelLarge]) {
        expect(style!.fontFamilyFallback, contains('Noto Color Emoji'), reason: '$brightness');
      }
    }
  });

  test('HINTS-001: a site that follows the app is told its theme mode', () {
    final site = WebViewModel(initUrl: 'https://example.com/');
    for (final (mode, told) in [
      (ThemeMode.dark, WebViewTheme.dark),
      (ThemeMode.light, WebViewTheme.light),
      (ThemeMode.system, WebViewTheme.system),
    ]) {
      _appTheme(mode);
      expect(site.effectiveTheme, told, reason: '$mode');
    }
  });

  // Each site kept its own copy of the app's theme, pushed to it where sites
  // were added, imported or launched, and an archive's open pushed nothing:
  // its sites told their pages light while the app was dark.
  test(
      'HINTS-001: a site an archive opens follows the app theme from its first '
      'build', () {
    _appTheme(ThemeMode.dark);
    final opened = WebViewModel.fromJson(
      WebViewModel(initUrl: 'https://vault.example/').toJson(),
      stateSetterF: null,
      isArchiveTier: true,
    );
    expect(opened.effectiveTheme, WebViewTheme.dark);
  });

  test('HINTS-004: the next launch reads the theme saved, and its sites follow it',
      () async {
    SharedPreferences.setMockInitialValues({});
    final before = ShellStore(SiteRuntime())
      ..theme = const AppThemeSettings(themeMode: ThemeMode.dark);
    await before.saveTheme();
    WebViewModel.appTheme = WebViewTheme.light;

    final after = ShellStore(SiteRuntime())
      ..loadTheme(await SharedPreferences.getInstance());

    expect(after.theme.themeMode, ThemeMode.dark);
    expect(WebViewModel(initUrl: 'https://example.com/').effectiveTheme,
        WebViewTheme.dark);
  });

  test('HINTS-004: with nothing saved, the sites follow the default', () async {
    SharedPreferences.setMockInitialValues({});
    ShellStore(SiteRuntime()).loadTheme(await SharedPreferences.getInstance());
    expect(WebViewModel.appTheme,
        const AppThemeSettings().themeMode.webViewTheme);
  });
}
