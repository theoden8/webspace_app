import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'helpers/localized.dart';

Widget _host(Widget child, {TextDirection? direction}) => localizedApp(Scaffold(
  body: direction == null
      ? child
      : Directionality(textDirection: direction, child: child),
));

SiteInfo _info({
  String? containerId,
  bool incognito = false,
  String? tabOf,
  String? openedFrom,
  int? containerColor,
}) =>
    SiteInfo(
      siteName: 'GitHub',
      pageUrl: 'https://github.com/theoden8',
      containerId: containerId,
      incognito: incognito,
      tabOf: tabOf,
      openedFrom: openedFrom,
      containerColor: containerColor,
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
      expect(find.text("GitHub's own container"), findsOneWidget,
          reason: 'the container names its site, never "this site"');
      expect(find.text('ws-gh'), findsOneWidget);
      expect(find.text('Tab of'), findsNothing);
      expect(find.text('Opened from'), findsNothing);
    });

    testWidgets('a hosted tab names the site whose tab it is', (tester) async {
      await tester.pumpWidget(_host(SiteInfoSheet(
        info: _info(containerId: 'ws-gh', tabOf: 'DuckDuckGo'),
      )));
      expect(find.text('Tab of'), findsOneWidget);
      expect(find.text('DuckDuckGo'), findsOneWidget);
      expect(find.text("GitHub's own container"), findsOneWidget);
    });

    testWidgets('a nested screen names the site it was opened from',
        (tester) async {
      await tester.pumpWidget(_host(SiteInfoSheet(
        info: _info(containerId: 'ws-gh', openedFrom: 'DuckDuckGo'),
      )));
      expect(find.text('Opened from'), findsOneWidget);
      expect(find.text('DuckDuckGo'), findsOneWidget);
    });

    testWidgets('the same site twice is said once', (tester) async {
      await tester.pumpWidget(_host(SiteInfoSheet(
        info: _info(containerId: 'ws-gh', tabOf: 'GitHub', openedFrom: 'GitHub'),
      )));
      expect(find.text('Tab of'), findsNothing);
      expect(find.text('Opened from'), findsNothing);
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

    testWidgets('the container row carries its colour (TAB-018)',
        (tester) async {
      Iterable<Color?> dots() => tester
          .widgetList<Container>(find.descendant(
            of: find.byType(SiteInfoSheet),
            matching: find.byType(Container),
          ))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.shape == BoxShape.circle)
          .map((d) => d.color);

      await tester.pumpWidget(_host(SiteInfoSheet(
        info: _info(containerId: 'ws-gh', containerColor: 2),
      )));
      expect(dots(), [ContainerColors.of(2, Brightness.light)]);

      await tester.pumpWidget(_host(SiteInfoSheet(
        info: _info(containerId: 'ws-gh'),
      )));
      expect(dots(), isEmpty, reason: 'no colour where none was given');
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
