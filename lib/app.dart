
import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';

import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/app_locale.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/screens/webspace_page.dart';

class WebSpaceApp extends StatefulWidget {
  @override
  _WebSpaceAppState createState() => _WebSpaceAppState();
}

class _WebSpaceAppState extends State<WebSpaceApp> {
  AppThemeSettings _themeSettings = const AppThemeSettings();

  void _setThemeSettings(AppThemeSettings settings) {
    setState(() {
      _themeSettings = settings;
    });
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<String>(
        valueListenable: AppPref.appLocaleOverride.listenable,
        builder: (context, localeTag, _) => _buildApp(localeFromTag(localeTag)),
      );

  Widget _buildApp(Locale? locale) {
    final Color accentColor = _themeSettings.accentColor.color;
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      // Lets every webview-hosting screen learn when an opaque route above it
      // pops, which re-attaches its platform view blank (PAUSE-024/BUG-001).
      navigatorObservers: [surfaceRouteObserver],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      // Fall back to English for any device locale we don't ship, instead of
      // gen_l10n's default of supportedLocales.first (alphabetically 'af').
      localeListResolutionCallback: (locales, supportedLocales) =>
          resolveSupportedLocale(locales, supported: supportedLocales),
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      theme: ThemeData(
        colorScheme: buildAccentColorScheme(accentColor, brightness: Brightness.light),
        scaffoldBackgroundColor: Color(0xFFFFFFFF),
      ),
      darkTheme: ThemeData(
        colorScheme: buildAccentColorScheme(accentColor, brightness: Brightness.dark),
        scaffoldBackgroundColor: Color(0xFF000000),
      ),
      themeMode: _themeSettings.themeMode,
      home: WebSpacePage(onThemeSettingsChanged: _setThemeSettings),
      debugShowCheckedModeBanner: false,
    );
  }
}
