import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_tab_strip.dart';

import 'helpers/real_app.dart';

/// A11Y-006: the chrome lays out at the system's largest text sizes. The real
/// app on a phone-sized screen, at 2.0 and at 3.1 (iOS AX5's body size), in
/// English and in German's long words, through the screens of the common
/// tasks: the webspaces, a site with its app bar, the drawer, Add site, App
/// Settings and each screen it opens. An overflow anywhere is a Flutter error
/// that fails the test; every control the walk taps must still be there to
/// tap, scrolled to if it went below the fold.
void main() {
  for (final locale in const [Locale('en'), Locale('de')]) {
    for (final scale in const [2.0, 3.1]) {
      testWidgets(
          'A11Y-006: the common screens lay out at ${scale}x text in ${locale.languageCode}',
          (tester) async {
        tester.view.physicalSize = const Size(390 * 3, 844 * 3);
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        tester.platformDispatcher.localesTestValue = [locale];
        addTearDown(() {
          tester.view.reset();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.platformDispatcher.clearLocalesTestValue();
        });
        final loc = await AppLocalizations.delegate.load(locale);

        Future<void> tap(Finder finder) async {
          if (finder.evaluate().isEmpty) {
            await tester.scrollUntilVisible(finder, 200,
                scrollable: find.byType(Scrollable).first);
          }
          await tester.ensureVisible(finder.first);
          await tester.pumpAndSettle();
          await tester.tap(finder.first);
          await settleRealApp(tester);
        }

        Future<void> back() async {
          await tester.binding.handlePopRoute();
          await settleRealApp(tester);
        }

        await pumpRealApp(tester, prefs: {'showTabStrip': true}, sites: [
          WebViewModel(
              initUrl: 'https://example.com',
              name: 'Gemeinschaftsverwaltungsportal'),
          WebViewModel(initUrl: 'https://news.example.org', name: 'News'),
        ]);

        await tap(find.byTooltip(loc.homeAppSettingsTooltip.toString()));
        expect(find.text(loc.appSettingsTitle.toString()), findsOneWidget);
        for (final row in [
          loc.appSettingsAppearance,
          loc.appSettingsBehaviour,
          loc.appSettingsNetwork,
          loc.appSettingsPrivacy,
          loc.appSettingsUserScripts,
          loc.appSettingsBackupAndArchives,
        ]) {
          await tap(find.text(row.toString()));
          await back();
        }
        await back();

        await tap(find.descendant(
            of: find.byType(ListTile), matching: find.text('All')));
        await tap(find.text('Gemeinschaftsverwaltungsportal'));
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.byType(SiteTabStrip), findsOneWidget);
        await tap(find.descendant(
            of: find.byType(SiteTabStrip), matching: find.text('News')));
        expect(find.descendant(of: find.byType(AppBar), matching: find.text('News')),
            findsOneWidget);

        await tap(find.byTooltip(
            MaterialLocalizations.of(tester.element(find.byType(AppBar)))
                .openAppDrawerTooltip));
        expect(find.text('News'), findsWidgets);
        await tap(find.text(loc.homeAddSite.toString()));
        expect(find.text(loc.addSiteScreenTitle.toString()), findsWidgets);
        await back();
      });
    }
  }
}
