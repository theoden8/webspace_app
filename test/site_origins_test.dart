import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/site_origins.dart';

void main() {
  const home = 'https://example.com/app';
  final site = SiteOrigins(home, claims: DomainClaim.implicitFor(home));

  test("PERM-001: a site owns its claimed hosts on its own scheme, no one "
      "else's", () {
    expect(site.owns('https://example.com'), isTrue);
    expect(site.owns('https://www.example.com'), isTrue);
    expect(site.owns('https://evil.com'), isFalse);
    expect(site.owns('https://example.com.evil.com'), isFalse);
    expect(
      site.owns('http://example.com'),
      isFalse,
      reason: 'a plain-http page of the host is not the https site',
    );
    expect(site.owns('about:blank'), isFalse);
    expect(site.owns('null'), isFalse);
  });

  test('PERM-001: explicit claims decide, not the address alone', () {
    final claimed = SiteOrigins(
      home,
      claims: [
        DomainClaim.exactHost('app.example.com'),
        DomainClaim.baseDomain('example.org'),
      ],
    );
    expect(claimed.owns('https://app.example.com'), isTrue);
    expect(claimed.owns('https://www.example.com'), isFalse);
    expect(claimed.owns('https://login.example.org'), isTrue);
  });

  test('PERM-001: where a request stands', () {
    expect(
      site.standing(top: 'https://example.com/a', frame: 'https://example.com'),
      Standing.own,
    );
    expect(
      site.standing(top: 'https://example.com', frame: 'https://ads.net'),
      Standing.embedded,
    );
    expect(
      site.standing(top: 'https://evil.com', frame: 'https://evil.com'),
      Standing.foreign,
    );
    expect(
      site.standing(top: 'https://evil.com', frame: 'https://example.com'),
      Standing.foreign,
      reason: "the site's page framed by a stranger answers for no one",
    );
  });

  test('PERM-001: one origin, whatever shape it was reported in', () {
    expect(originOf('https://example.com/path?q=1#f'), 'https://example.com');
    expect(originOf('https://example.com/'), 'https://example.com');
    expect(originOf('https://example.com:8443/x'), 'https://example.com:8443');
    expect(originOf('about:blank'), 'about:blank');
  });
}
