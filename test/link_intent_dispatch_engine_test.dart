import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
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
}
