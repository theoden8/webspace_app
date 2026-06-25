import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  group('LinkHandlingSettingsScreen — LIR-008', () {
    testWidgets('master switch flips and notifies', (tester) async {
      bool? lastValue;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LinkHandlingSettingsScreen(
          enabled: true,
          onEnabledChanged: (v) => lastValue = v,
          claimDomains: false,
          onClaimDomainsChanged: (_) {},
          sites: const [],
          onOpenSiteEditor: (_) {},
        ),
      ));
      expect(find.text('Handle shared links'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(lastValue, false);
    });

    testWidgets('claim-domains switch defaults off, flips and notifies',
        (tester) async {
      bool? lastValue;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LinkHandlingSettingsScreen(
          enabled: true,
          onEnabledChanged: (_) {},
          claimDomains: false,
          onClaimDomainsChanged: (v) => lastValue = v,
          sites: const [],
          onOpenSiteEditor: (_) {},
        ),
      ));
      expect(find.text('Claim domains from shared links'), findsOneWidget);
      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      expect(lastValue, true);
    });

    testWidgets('claim-domains switch is disabled while master is off',
        (tester) async {
      bool changed = false;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LinkHandlingSettingsScreen(
          enabled: false,
          onEnabledChanged: (_) {},
          claimDomains: false,
          onClaimDomainsChanged: (_) => changed = true,
          sites: const [],
          onOpenSiteEditor: (_) {},
        ),
      ));
      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      expect(changed, isFalse);
    });

    testWidgets('routing overview lists each site with claims as chips',
        (tester) async {
      final a = WebViewModel(initUrl: 'https://twitter.com/');
      final b = WebViewModel(initUrl: 'https://mastodon.social/')
        ..domainClaims = [
          DomainClaim.exactHost('mastodon.social'),
          DomainClaim.wildcardSubdomain('mastodon.social'),
        ];
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LinkHandlingSettingsScreen(
          enabled: true,
          onEnabledChanged: (_) {},
          claimDomains: false,
          onClaimDomainsChanged: (_) {},
          sites: [a, b],
          onOpenSiteEditor: (_) {},
        ),
      ));
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
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LinkHandlingSettingsScreen(
          enabled: true,
          onEnabledChanged: (_) {},
          claimDomains: false,
          onClaimDomainsChanged: (_) {},
          sites: [a],
          onOpenSiteEditor: (s) => tappedSite = s,
        ),
      ));
      await tester.tap(find.text('Twitter'));
      await tester.pump();
      expect(tappedSite, same(a));
    });

    testWidgets(
        'master switch off: subtitle reflects state and routing list still renders',
        (tester) async {
      final a = WebViewModel(initUrl: 'https://twitter.com/');
      a.name = 'Twitter';
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LinkHandlingSettingsScreen(
          enabled: false,
          onEnabledChanged: (_) {},
          claimDomains: false,
          onClaimDomainsChanged: (_) {},
          sites: [a],
          onOpenSiteEditor: (_) {},
        ),
      ));
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
