import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/redirect_domain_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/controllers/site_route.dart';
import 'package:webspace/web_view_model.dart';

RoutableSite _site({
  required String initUrl,
  required List<DomainClaim> domainClaims,
  String id = 'site',
}) => SiteRoute(
  WebViewModel(
    initUrl: initUrl,
    domainClaims: domainClaims,
    siteId: SiteId(id),
  ),
);

void main() {
  final guardian = _site(
    initUrl: 'https://theguardian.co.uk/',
    domainClaims: [DomainClaim.baseDomain('theguardian.co.uk')],
  );

  test('offers the resolved base domain without its www prefix', () {
    expect(
      redirectDomainClaim(
        guardian,
        resolvedUrl: Uri.parse('https://www.theguardian.com/uk'),
        sites: [guardian],
      ),
      DomainClaim.baseDomain('theguardian.com'),
    );
  });

  test('already covered domains and non-web documents are not offered', () {
    for (final url in [
      'https://www.theguardian.co.uk/news',
      'about:blank',
      'file:///page.html',
      'data:text/html,hello',
    ]) {
      expect(
        redirectDomainClaim(
          guardian,
          resolvedUrl: Uri.parse(url),
          sites: [guardian],
        ),
        isNull,
        reason: url,
      );
    }
  });

  test('non-default ports get an exact claim, never the whole host', () {
    expect(
      redirectDomainClaim(
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
        redirectDomainClaim(
          guardian,
          resolvedUrl: Uri.parse('https://www.theguardian.com/uk'),
          sites: [guardian, other],
        ),
        isNull,
      );
    }
  });
}
