import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/redirect_domain_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/controllers/site_route.dart';
import 'package:webspace/web_view_model.dart';

SiteRoute _site({
  required String initUrl,
  required List<DomainClaim> domainClaims,
  String id = 'site',
  ExternalLinkMode mode = ExternalLinkMode.inApp,
}) => SiteRoute(
  WebViewModel(
    initUrl: initUrl,
    domainClaims: domainClaims,
    externalLinkMode: mode,
    siteId: SiteId(id),
  ),
);

DomainClaim? _claim(
  SiteRoute site, {
  required Uri resolvedUrl,
  required List<RoutableSite> sites,
}) => redirectDomainClaim(
  site,
  resolvedUrl: resolvedUrl,
  navigationDecision: site.model.decideUserOpenedLink(
    resolvedUrl.toString(),
    isActive: true,
  ),
  sites: sites,
);

void main() {
  final guardian = _site(
    initUrl: 'https://theguardian.co.uk/',
    domainClaims: [DomainClaim.baseDomain('theguardian.co.uk')],
  );

  for (final mode in ExternalLinkMode.values) {
    test('internal aliases stay internal in ${mode.name} mode', () {
      for (final (home, target) in [
        ('https://claude.ai/', 'https://www.anthropic.com/'),
        ('https://discordapp.com/', 'https://discord.com/login'),
        ('https://google.co.uk/', 'https://www.google.com/'),
      ]) {
        final site = _site(initUrl: home, domainClaims: [], mode: mode);
        expect(
          _claim(site, resolvedUrl: Uri.parse(target), sites: [site]),
          isNull,
          reason: '$home → $target',
        );
      }
    });

    test(
      'external links qualify in ${mode.name} mode with or without claims',
      () {
        for (final claimed in [false, true]) {
          final site = _site(
            initUrl: 'https://theguardian.co.uk/',
            domainClaims: [
              if (claimed) DomainClaim.baseDomain('theguardian.com'),
            ],
            mode: mode,
          );
          expect(
            _claim(
              site,
              resolvedUrl: Uri.parse('https://www.theguardian.com/uk'),
              sites: [site],
            ),
            DomainClaim.baseDomain('theguardian.com'),
          );
        }
      },
    );
  }

  test('offers the resolved base domain without its www prefix', () {
    expect(
      _claim(
        guardian,
        resolvedUrl: Uri.parse('https://www.theguardian.com/uk'),
        sites: [guardian],
      ),
      DomainClaim.baseDomain('theguardian.com'),
    );
  });

  test('same-domain redirects and non-web documents are not offered', () {
    for (final url in [
      'https://theguardian.co.uk/uk',
      'https://www.theguardian.co.uk/news',
      'https://accounts.theguardian.co.uk/login',
      'http://theguardian.co.uk/',
      'https://theguardian.co.uk:8443/news',
      'about:blank',
      'file:///page.html',
      'data:text/html,hello',
    ]) {
      expect(
        _claim(guardian, resolvedUrl: Uri.parse(url), sites: [guardian]),
        isNull,
        reason: url,
      );
    }
  });

  test('an already claimed different domain can still become the homepage', () {
    final site = _site(
      initUrl: 'https://theguardian.co.uk/',
      domainClaims: [
        DomainClaim.baseDomain('theguardian.co.uk'),
        DomainClaim.baseDomain('theguardian.com'),
      ],
    );
    expect(
      _claim(
        site,
        resolvedUrl: Uri.parse('https://www.theguardian.com/uk'),
        sites: [site],
      ),
      DomainClaim.baseDomain('theguardian.com'),
    );
  });

  test('private suffix tenants are different domains', () {
    final site = _site(initUrl: 'https://old.github.io/', domainClaims: []);
    expect(
      _claim(
        site,
        resolvedUrl: Uri.parse('https://new.github.io/'),
        sites: [site],
      ),
      DomainClaim.baseDomain('new.github.io'),
    );
  });

  test('non-default ports get an exact claim, never the whole host', () {
    expect(
      _claim(
        guardian,
        resolvedUrl: Uri.parse('http://localhost:8080/news'),
        sites: [guardian],
      ),
      DomainClaim.exactHost('localhost:8080'),
    );
  });

  test('overlapping and hijacked domains are not offered', () {
    for (final other in [
      _site(id: 'other', initUrl: 'https://theguardian.com/', domainClaims: []),
      _site(
        id: 'other',
        initUrl: 'https://other.example/',
        domainClaims: [DomainClaim.exactHost('www.theguardian.com')],
      ),
    ]) {
      expect(
        _claim(
          guardian,
          resolvedUrl: Uri.parse('https://www.theguardian.com/uk'),
          sites: [guardian, other],
        ),
        isNull,
      );
    }
  });
}
