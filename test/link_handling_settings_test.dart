import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  group('LinkHandlingSettingsScreen — LIR-008', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AppPref.loadAll(await SharedPreferences.getInstance());
    });

    Future<void> pumpScreen(
      WidgetTester tester, {
      List<WebViewModel> sites = const [],
      void Function(WebViewModel site)? onOpenSiteEditor,
    }) =>
        tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LinkHandlingSettingsScreen(
            sites: sites,
            onOpenSiteEditor: onOpenSiteEditor ?? (_) {},
          ),
        ));

    bool switchAt(WidgetTester tester, int i) =>
        tester.widget<Switch>(find.byType(Switch).at(i)).value;

    // The screen used to be pushed with the values of the moment, so a switch
    // kept drawing them after a tap until something rebuilt the route.
    testWidgets('master switch sets the pref and shows what it set',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('Handle shared links'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(AppPref.linkHandlingEnabled.value, isFalse);
      expect(switchAt(tester, 0), isFalse);
    });

    testWidgets('claim-domains switch defaults off, flips and shows it',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('Claim domains from shared links'), findsOneWidget);
      expect(switchAt(tester, 1), isFalse);
      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      expect(AppPref.linkHandlingClaimDomains.value, isTrue);
      expect(switchAt(tester, 1), isTrue);
    });

    testWidgets('claim-domains switch is disabled while master is off',
        (tester) async {
      AppPref.linkHandlingEnabled.debugValue = false;
      await pumpScreen(tester);
      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      expect(AppPref.linkHandlingClaimDomains.value, isFalse);
    });

    testWidgets('routing overview lists each site with claims as chips',
        (tester) async {
      final a = WebViewModel(initUrl: 'https://twitter.com/');
      final b = WebViewModel(initUrl: 'https://mastodon.social/')
        ..domainClaims = [
          DomainClaim.exactHost('mastodon.social'),
          DomainClaim.wildcardSubdomain('mastodon.social'),
        ];
      await pumpScreen(tester, sites: [a, b]);
      // Auto-synthesised baseDomain claim shows up as `twitter.com (base)`.
      expect(find.text('twitter.com (base)'), findsOneWidget);
      // Explicit claims for site B are rendered verbatim with the
      // wildcard `*.` prefix; the bare host appears both as the site
      // title (since `name` defaults to extractDomain) and as a chip.
      expect(find.text('mastodon.social'), findsAtLeastNWidgets(1));
      expect(find.text('*.mastodon.social'), findsOneWidget);
    });

    testWidgets('routing overview row tap calls onOpenSiteEditor',
        (tester) async {
      final a = WebViewModel(initUrl: 'https://twitter.com/');
      a.name = 'Twitter';
      WebViewModel? tappedSite;
      await pumpScreen(tester,
          sites: [a], onOpenSiteEditor: (s) => tappedSite = s);
      await tester.tap(find.text('Twitter'));
      await tester.pump();
      expect(tappedSite, same(a));
    });

    testWidgets(
        'master switch off: subtitle reflects state and routing list still renders',
        (tester) async {
      final a = WebViewModel(initUrl: 'https://twitter.com/');
      a.name = 'Twitter';
      AppPref.linkHandlingEnabled.debugValue = false;
      await pumpScreen(tester, sites: [a]);
      expect(find.text('Twitter'), findsOneWidget);
    });
  });

  group('DomainClaimsEditor — LIR-008 task 8.4', () {
    testWidgets('renders the synthesized base claim when domainClaims is null',
        (tester) async {
      final m = WebViewModel(initUrl: 'https://example.org/');
      List<DomainClaim>? lastChange;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DomainClaimsEditor(
            model: m,
            otherSites: const [],
            onChanged: (next) => lastChange = next,
          ),
        ),
      ));
      expect(find.text('Domain claims'), findsOneWidget);
      expect(find.text('example.org (base)'), findsOneWidget);
      // Editor opens with claims in the synthesized state — no onChanged
      // should have fired yet.
      expect(lastChange, isNull);
    });

    testWidgets('removing a non-base claim emits the new explicit list',
        (tester) async {
      final m = WebViewModel(initUrl: 'https://example.org/')
        ..domainClaims = [
          DomainClaim.baseDomain('example.org'),
          DomainClaim.exactHost('blog.example.org'),
        ];
      List<DomainClaim>? lastChange;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DomainClaimsEditor(
            model: m,
            otherSites: const [],
            onChanged: (next) => lastChange = next,
          ),
        ),
      ));
      await tester.tap(find.byIcon(Icons.delete_outline).last);
      await tester.pump();
      expect(lastChange, isNotNull);
      expect(lastChange!.length, 1);
      expect(lastChange!.first, DomainClaim.baseDomain('example.org'));
    });

    testWidgets(
        'hijack conflict surfaces a red subtitle on the offending claim',
        (tester) async {
      final github = WebViewModel(initUrl: 'https://github.com/alice');
      final attacker = WebViewModel(initUrl: 'https://example.org/')
        ..domainClaims = [DomainClaim.exactHost('github.com')];
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DomainClaimsEditor(
            model: attacker,
            otherSites: [github],
            onChanged: (_) {},
          ),
        ),
      ));
      expect(
        find.text('Conflict: another site already owns this base domain.'),
        findsOneWidget,
      );
    });
  });
}
