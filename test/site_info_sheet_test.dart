import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'package:webspace/widgets/url_bar.dart';

Widget _host(Widget child, {TextDirection? direction}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: direction == null
            ? child
            : Directionality(textDirection: direction, child: child),
      ),
    );

SiteInfo _info({String? containerId, bool incognito = false}) => SiteInfo(
      siteName: 'GitHub',
      pageUrl: 'https://github.com/theoden8',
      containerId: containerId,
      incognito: incognito,
    );

void main() {
  group('SiteInfo.containerKind', () {
    test('a bound container is the site\'s own', () {
      expect(_info(containerId: 'ws-gh').containerKind, SiteContainerKind.own);
      expect(_info(containerId: 'ws-gh', incognito: true).containerKind,
          SiteContainerKind.own,
          reason: 'Android binds a named profile even under incognito');
    });

    test('incognito without one is ephemeral', () {
      expect(_info(incognito: true).containerKind, SiteContainerKind.ephemeral);
    });

    test('otherwise the store is shared', () {
      expect(_info().containerKind, SiteContainerKind.shared);
    });
  });

  group('the container rule', () {
    test('a site owns a profile only where containers exist', () {
      expect(
        siteOwnsContainerProfile(
            containersSupported: true,
            containerSiteIdentifier: 'gh',
            incognito: false),
        isTrue,
      );
      expect(
        siteOwnsContainerProfile(
            containersSupported: false,
            containerSiteIdentifier: 'gh',
            incognito: false),
        isFalse,
      );
      expect(
        siteOwnsContainerProfile(
            containersSupported: true,
            containerSiteIdentifier: null,
            incognito: false),
        isFalse,
      );
    });

    test('containerIdFor binds nothing before containers are known', () {
      // cachedSupported is false until the startup probe resolves, which a
      // unit test never runs.
      expect(containerIdFor(siteId: 'gh', incognito: false), isNull);
    });
  });

  group('SiteInfoSheet', () {
    testWidgets('names the site, the page and the container', (tester) async {
      await tester.pumpWidget(_host(SiteInfoSheet(
        info: _info(containerId: 'ws-gh'),
      )));
      expect(find.text('Site info'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('https://github.com/theoden8'), findsOneWidget);
      expect(find.text("This site's own container"), findsOneWidget);
      expect(find.text('ws-gh'), findsOneWidget);
    });

    testWidgets('an ephemeral store shows no identifier', (tester) async {
      await tester.pumpWidget(_host(SiteInfoSheet(
        info: _info(incognito: true),
      )));
      expect(find.text('Private, discarded when closed'), findsOneWidget);
      expect(find.textContaining('ws-'), findsNothing);
    });

    testWidgets('the shared store says so', (tester) async {
      await tester.pumpWidget(_host(SiteInfoSheet(info: _info())));
      expect(find.text('Shared, cookies swapped per site'), findsOneWidget);
    });
  });

  group('UrlBar info button', () {
    testWidgets('absent without a handler', (tester) async {
      await tester.pumpWidget(_host(UrlBar(
        currentUrl: 'https://github.com/',
        onUrlSubmitted: (_) {},
      )));
      expect(find.byTooltip('Site info'), findsNothing);
    });

    testWidgets('opens the sheet handler, and gives way to Go while editing',
        (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(UrlBar(
        currentUrl: 'https://github.com/',
        onUrlSubmitted: (_) {},
        onSiteInfo: () => opened++,
      )));
      await tester.tap(find.byTooltip('Site info'));
      expect(opened, 1);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byTooltip('Site info'), findsNothing);
      expect(find.byTooltip('Go'), findsOneWidget);
    });

    testWidgets('sits at the trailing end in either direction',
        (tester) async {
      for (final direction in TextDirection.values) {
        await tester.pumpWidget(_host(
          UrlBar(
            currentUrl: 'https://github.com/',
            onUrlSubmitted: (_) {},
            onSiteInfo: () {},
          ),
          direction: direction,
        ));
        final button = tester.getCenter(find.byTooltip('Site info')).dx;
        final field = tester.getCenter(find.byType(TextField)).dx;
        expect(
          direction == TextDirection.ltr ? button > field : button < field,
          isTrue,
          reason: '$direction',
        );
      }
    });
  });
}
