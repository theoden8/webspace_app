import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/web_view_model.dart' show getNormalizedDomain;

class _Site implements DispatchableSite {
  @override
  final String siteId;
  @override
  final String initUrl;
  @override
  final List<DomainClaim> domainClaims;
  @override
  final bool incognito;
  @override
  final bool alwaysOpenHome;

  _Site({
    required this.siteId,
    required this.initUrl,
    required this.domainClaims,
    this.incognito = false,
    this.alwaysOpenHome = false,
  });

  @override
  String get navigationDomain => getNormalizedDomain(initUrl);
}

void main() {
  group('LinkIntentDispatchEngine.dispatch — InboundUrl', () {
    test('non-http(s) inbound URL yields DispatchUnsupported', () {
      final action = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse('javascript:alert(1)')),
        sites: const [],
      );
      expect(action, isA<DispatchUnsupported>());
    });

    test('webspace:// wraps unwrap to inner http(s) target', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.exactHost('duckduckgo.com')],
      );
      final action = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse(
            'webspace://open?url=https%3A%2F%2Fduckduckgo.com%2F%3Fq%3Dx')),
        sites: [ddg],
      );
      expect(action, isA<DispatchOpenInMain>());
      expect((action as DispatchOpenInMain).siteId, 'ddg');
      expect(action.url, 'https://duckduckgo.com/?q=x');
    });

    test('single resolver match + in-domain + regular site -> open-in-main', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
      );
      final action = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse('https://duckduckgo.com/?q=foo')),
        sites: [ddg],
      );
      expect(action, isA<DispatchOpenInMain>());
      final m = action as DispatchOpenInMain;
      expect(m.siteId, 'ddg');
      expect(m.disposeBeforeLoad, isFalse);
      expect(m.wipeContainer, isFalse);
      expect(m.clearInMemoryCookies, isFalse);
    });

    test('incognito site triggers full reset flags on in-domain share', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
        incognito: true,
      );
      final m = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse('https://duckduckgo.com/?q=foo')),
        sites: [ddg],
      ) as DispatchOpenInMain;
      expect(m.disposeBeforeLoad, isTrue);
      expect(m.wipeContainer, isTrue);
      expect(m.clearInMemoryCookies, isTrue);
    });

    test('alwaysOpenHome triggers dispose only (cookies preserved)', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
        alwaysOpenHome: true,
      );
      final m = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse('https://duckduckgo.com/?q=foo')),
        sites: [ddg],
      ) as DispatchOpenInMain;
      expect(m.disposeBeforeLoad, isTrue);
      expect(m.wipeContainer, isFalse);
      expect(m.clearInMemoryCookies, isFalse);
    });

    test('ambiguous resolver -> picker with two winners', () {
      final a = _Site(
        siteId: 'A',
        initUrl: 'https://reddit.com/',
        domainClaims: [DomainClaim.exactHost('reddit.com')],
      );
      final b = _Site(
        siteId: 'B',
        initUrl: 'https://reddit.com/',
        domainClaims: [DomainClaim.exactHost('reddit.com')],
      );
      final action = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse('https://reddit.com/r/x')),
        sites: [a, b],
      );
      expect(action, isA<DispatchShowPicker>());
      final p = action as DispatchShowPicker;
      expect(p.winnerSiteIds, containsAll(['A', 'B']));
      expect(p.offerBind, isTrue);
      expect(p.offerCreate, isTrue);
    });

    test('no resolver match -> picker with no winners', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
      );
      final action = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse('https://f-droid.org/packages/foo')),
        sites: [ddg],
      );
      expect(action, isA<DispatchShowPicker>());
      final p = action as DispatchShowPicker;
      expect(p.winnerSiteIds, isEmpty);
      expect(p.offerBind, isTrue);
      expect(p.offerCreate, isTrue);
    });

    test('no sites at all -> picker with offerBind=false', () {
      final action = LinkIntentDispatchEngine.dispatch(
        payload: InboundUrl(Uri.parse('https://example.org/')),
        sites: const [],
      );
      final p = action as DispatchShowPicker;
      expect(p.winnerSiteIds, isEmpty);
      expect(p.offerBind, isFalse);
      expect(p.offerCreate, isTrue);
    });
  });

  group('LinkIntentDispatchEngine.openInChosen — LIR-011 main vs nested', () {
    test('cross-domain user pick -> nested (not main webview)', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
      );
      final action = LinkIntentDispatchEngine.openInChosen(
        inbound: Uri.parse('https://f-droid.org/packages/foo'),
        site: ddg,
      );
      expect(action, isA<DispatchOpenNested>());
      expect((action as DispatchOpenNested).siteId, 'ddg');
      expect(action.url, 'https://f-droid.org/packages/foo');
    });

    test('in-domain user pick on regular site -> main webview', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
      );
      final action = LinkIntentDispatchEngine.openInChosen(
        inbound: Uri.parse('https://duckduckgo.com/?q=foo'),
        site: ddg,
      );
      expect(action, isA<DispatchOpenInMain>());
      expect((action as DispatchOpenInMain).disposeBeforeLoad, isFalse);
    });
  });

  group('LinkIntentDispatchEngine.bindToSite — LIR-010 option 2', () {
    test('cross-domain bind: claim additions returned + nested follow-up', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
      );
      final action = LinkIntentDispatchEngine.bindToSite(
        inbound: Uri.parse('https://f-droid.org/packages/foo'),
        site: ddg,
      );
      expect(action, isA<DispatchBindAndOpen>());
      final b = action as DispatchBindAndOpen;
      expect(b.chosenSiteId, 'ddg');
      expect(b.claimAdditions, [
        DomainClaim.exactHost('f-droid.org'),
        DomainClaim.wildcardSubdomain('f-droid.org'),
      ]);
      // The follow-up still respects the existing site's
      // navigationDomain, so cross-domain stays nested.
      expect(b.followUp, isA<DispatchOpenNested>());
    });

    test('same-domain bind: follow-up is main-webview load', () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [],
      );
      final action = LinkIntentDispatchEngine.bindToSite(
        inbound: Uri.parse('https://www.duckduckgo.com/?q=foo'),
        site: ddg,
      );
      final b = action as DispatchBindAndOpen;
      expect(b.followUp, isA<DispatchOpenInMain>());
    });
  });

  group('LinkIntentDispatchEngine.sendToSite — discussion #439 opt-in', () {
    final ddg = _Site(
      siteId: 'ddg',
      initUrl: 'https://duckduckgo.com/',
      domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
    );

    test('claimDomain:true binds (adds claims) like bindToSite', () {
      final action = LinkIntentDispatchEngine.sendToSite(
        inbound: Uri.parse('https://f-droid.org/packages/foo'),
        site: ddg,
        claimDomain: true,
      );
      expect(action, isA<DispatchBindAndOpen>());
      final b = action as DispatchBindAndOpen;
      expect(b.claimAdditions, [
        DomainClaim.exactHost('f-droid.org'),
        DomainClaim.wildcardSubdomain('f-droid.org'),
      ]);
    });

    test('claimDomain:false just opens — no claim mutation (cross-domain)', () {
      final action = LinkIntentDispatchEngine.sendToSite(
        inbound: Uri.parse('https://f-droid.org/packages/foo'),
        site: ddg,
        claimDomain: false,
      );
      expect(action, isA<DispatchOpenNested>());
      expect(action, isNot(isA<DispatchBindAndOpen>()));
      expect((action as DispatchOpenNested).siteId, 'ddg');
      expect(action.url, 'https://f-droid.org/packages/foo');
    });

    test('claimDomain:false in-domain opens main webview, no reset/claim', () {
      final action = LinkIntentDispatchEngine.sendToSite(
        inbound: Uri.parse('https://duckduckgo.com/?q=foo'),
        site: ddg,
        claimDomain: false,
      );
      expect(action, isA<DispatchOpenInMain>());
      expect((action as DispatchOpenInMain).disposeBeforeLoad, isFalse);
    });
  });

  group('LinkIntentDispatchEngine.createNew — LIR-010 option 3', () {
    test('strips path/query/fragment and seeds baseDomain claim', () {
      final action = LinkIntentDispatchEngine.createNew(
        inbound:
            Uri.parse('https://example.org/articles/foo?utm=share#top'),
      );
      expect(action, isA<DispatchCreateSite>());
      final c = action as DispatchCreateSite;
      expect(c.home, 'https://example.org/');
      expect(c.fullUrl, 'https://example.org/articles/foo?utm=share#top');
      expect(c.initialClaims, [DomainClaim.baseDomain('example.org')]);
    });

    test('non-http(s) returns DispatchUnsupported', () {
      final action = LinkIntentDispatchEngine.createNew(
        inbound: Uri.parse('ftp://example.org/'),
      );
      expect(action, isA<DispatchUnsupported>());
    });

    test('non-default port seeds an exactHost host:port claim, no wildcard',
        () {
      final action = LinkIntentDispatchEngine.createNew(
        inbound: Uri.parse('http://localhost:8080/admin?token=x'),
      );
      final c = action as DispatchCreateSite;
      expect(c.home, 'http://localhost:8080/');
      expect(c.initialClaims, [DomainClaim.exactHost('localhost:8080')]);
    });
  });

  group('LinkIntentDispatchEngine.dispatch — InboundHtml — LIR-012', () {
    test('HTML payload short-circuits to create-from-html, ignoring sites',
        () {
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
      );
      final action = LinkIntentDispatchEngine.dispatch(
        payload: const InboundHtml(
          content: '<html><body>hi</body></html>',
          suggestedTitle: 'My Page',
          sourceUri: 'content://example/foo.html',
        ),
        sites: [ddg],
      );
      expect(action, isA<DispatchCreateSiteFromHtml>());
      final c = action as DispatchCreateSiteFromHtml;
      expect(c.html, '<html><body>hi</body></html>');
      expect(c.suggestedTitle, 'My Page');
    });

    test('empty HTML payload yields DispatchUnsupported', () {
      final action = LinkIntentDispatchEngine.dispatch(
        payload: const InboundHtml(content: ''),
        sites: const [],
      );
      expect(action, isA<DispatchUnsupported>());
    });

    test('HTML payload offers no picker / bind / open paths', () {
      // Even with multiple sites and an exact-host candidate, an HTML
      // payload never goes through the resolver — there is no URL to
      // route. Sanity check via direct kind checks.
      final ddg = _Site(
        siteId: 'ddg',
        initUrl: 'https://example.org/',
        domainClaims: [DomainClaim.exactHost('example.org')],
      );
      final action = LinkIntentDispatchEngine.dispatch(
        payload: const InboundHtml(content: '<p>hi</p>'),
        sites: [ddg, ddg],
      );
      expect(action, isNot(isA<DispatchShowPicker>()));
      expect(action, isNot(isA<DispatchOpenInMain>()));
      expect(action, isNot(isA<DispatchOpenNested>()));
      expect(action, isNot(isA<DispatchCreateSite>()));
      expect(action, isA<DispatchCreateSiteFromHtml>());
    });
  });

  group('LinkIntentDispatchEngine.openInChosen — search origin (LIR-030)', () {
    _Site ddg({bool incognito = false, bool alwaysOpenHome = false}) => _Site(
          siteId: 'ddg',
          initUrl: 'https://duckduckgo.com/',
          domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
          incognito: incognito,
          alwaysOpenHome: alwaysOpenHome,
        );
    final query = Uri.parse('https://duckduckgo.com/?q=flutter+tabs');

    test('a search never resets the search site', () {
      for (final site in [
        ddg(incognito: true),
        ddg(alwaysOpenHome: true),
      ]) {
        final action = LinkIntentDispatchEngine.openInChosen(
          inbound: query,
          site: site,
          origin: InboundOrigin.search,
        ) as DispatchOpenInMain;
        expect(action.url, query.toString());
        expect(action.disposeBeforeLoad, isFalse);
        expect(action.wipeContainer, isFalse);
        expect(action.clearInMemoryCookies, isFalse);
      }
    });

    test('a search opens a new tab exactly when tabs are on', () {
      for (final tabs in [true, false]) {
        final action = LinkIntentDispatchEngine.openInChosen(
          inbound: query,
          site: ddg(),
          origin: InboundOrigin.search,
          tabsEnabled: tabs,
        ) as DispatchOpenInMain;
        expect(action.newTab, tabs);
      }
    });

    test('a pick from the share picker keeps the LIR-011 reset and no tab', () {
      final action = LinkIntentDispatchEngine.openInChosen(
        inbound: query,
        site: ddg(incognito: true),
        tabsEnabled: true,
      ) as DispatchOpenInMain;
      expect(action.wipeContainer, isTrue);
      expect(action.newTab, isFalse);
    });

    test('a search address off the site\'s domain nests with its posture', () {
      final searx = _Site(
        siteId: 'searx',
        initUrl: 'https://searx.example/',
        domainClaims: const [],
      );
      final action = LinkIntentDispatchEngine.openInChosen(
        inbound: query,
        site: searx,
        origin: InboundOrigin.search,
        tabsEnabled: true,
      );
      expect(action, isA<DispatchOpenNested>());
    });
  });

  group('LinkIntentDispatchEngine.routeToTab (LIR-032)', () {
    final ddg = _Site(
      siteId: 'ddg',
      initUrl: 'https://duckduckgo.com/',
      domainClaims: [DomainClaim.baseDomain('duckduckgo.com')],
    );
    final gh = _Site(
      siteId: 'gh',
      initUrl: 'https://github.com/',
      domainClaims: [DomainClaim.baseDomain('github.com')],
    );
    final workGh = _Site(
      siteId: 'work-gh',
      initUrl: 'https://github.com/work',
      domainClaims: [DomainClaim.baseDomain('github.com')],
    );
    final pages = _Site(
      siteId: 'cb',
      initUrl: 'https://codeberg.org/',
      domainClaims: [DomainClaim.baseDomain('codeberg.page')],
    );

    DispatchAction? route(
      String url, {
      List<_Site>? hosts,
      List<OutboundPreference> prefs = const [],
      bool tabs = true,
      bool containers = true,
      bool kiosk = false,
      bool gesture = true,
    }) =>
        LinkIntentDispatchEngine.routeToTab(
          url: Uri.parse(url),
          urlNavigationDomain: getNormalizedDomain(url),
          tabsEnabled: tabs,
          containersActive: containers,
          kioskLocked: kiosk,
          hadGesture: gesture,
          source: ddg,
          sourcePrefs: prefs,
          hosts: () => hosts ?? [ddg, gh],
        );

    test('a link into one of the user\'s sites opens as its tab', () {
      final action = route('https://github.com/x');
      expect(action, isA<DispatchOpenInTab>());
      expect((action as DispatchOpenInTab).siteId, 'gh');
      expect(action.url, 'https://github.com/x');
    });

    test('whatever the routing switch says: it is not an input', () {
      // routeToTab takes no routeOutboundLinks, by design.
      expect(route('https://github.com/x'), isA<DispatchOpenInTab>());
    });

    test('tabs off, the legacy engine, a locked kiosk or no gesture: no tab',
        () {
      expect(route('https://github.com/x', tabs: false), isNull);
      expect(route('https://github.com/x', containers: false), isNull);
      expect(route('https://github.com/x', kiosk: true), isNull);
      expect(route('https://github.com/x', gesture: false), isNull);
    });

    test('a site that is not the user\'s stays nested', () {
      expect(route('https://medium.com/x'), isNull);
    });

    test('a claim outside a site\'s navigation domain makes no tab', () {
      expect(route('https://codeberg.page/docs', hosts: [ddg, pages]), isNull);
    });

    test('two sites that can run it ask', () {
      final action = route('https://github.com/x', hosts: [ddg, gh, workGh]);
      expect(action, isA<DispatchShowPicker>());
      final picker = action as DispatchShowPicker;
      expect(picker.asTab, isTrue);
      expect(picker.source, 'ddg');
      expect(picker.winnerSiteIds, unorderedEquals(['gh', 'work-gh']));
    });

    test('the source\'s preference decides between them', () {
      final action = route(
        'https://github.com/x',
        hosts: [ddg, gh, workGh],
        prefs: [
          OutboundPreference(
            claim: DomainClaim.baseDomain('github.com'),
            targetSiteId: 'work-gh',
          ),
        ],
      );
      expect((action as DispatchOpenInTab).siteId, 'work-gh');
    });
  });
}
