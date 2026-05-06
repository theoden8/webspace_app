import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/link_routing_service.dart';

class _Site implements RoutableSite {
  @override
  final String siteId;
  @override
  final String initUrl;
  @override
  final List<DomainClaim> domainClaims;

  const _Site(this.siteId, this.initUrl, this.domainClaims);
}

void main() {
  group('DomainClaim canonicalization', () {
    test('lowercases, strips scheme and port, drops `*.` prefix', () {
      expect(DomainClaim.exactHost('Twitter.COM').value, 'twitter.com');
      expect(DomainClaim.exactHost('https://Mail.google.com:443').value,
          'mail.google.com');
      expect(DomainClaim.wildcardSubdomain('*.Mastodon.Social').value,
          'mastodon.social');
      expect(DomainClaim.exactHost('  example.org  ').value, 'example.org');
    });

    test('value-equality respects kind', () {
      expect(DomainClaim.exactHost('a.com'),
          equals(DomainClaim.exactHost('A.COM')));
      expect(DomainClaim.exactHost('a.com'),
          isNot(equals(DomainClaim.wildcardSubdomain('a.com'))));
    });

    test('JSON round-trip preserves kind and value', () {
      final c = DomainClaim.wildcardSubdomain('Example.Org');
      final json = c.toJson();
      final back = DomainClaim.fromJson(json);
      expect(back, equals(c));
      expect(back.kind, DomainClaimKind.wildcardSubdomain);
      expect(back.value, 'example.org');
    });
  });

  group('LinkRoutingService.resolve - LIR-002', () {
    test('exactHost beats wildcardSubdomain on same domain', () {
      final a = _Site('A', 'https://mastodon.social/', [
        DomainClaim.wildcardSubdomain('mastodon.social'),
      ]);
      final b = _Site('B', 'https://mastodon.social/@me', [
        DomainClaim.exactHost('mastodon.social'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://mastodon.social/@user'),
        [a, b],
      );
      expect(r, isA<RoutingSingle>());
      expect((r as RoutingSingle).site.siteId, 'B');
    });

    test('wildcardSubdomain matches sub but not the bare base host', () {
      final a = _Site('A', 'https://mastodon.social/', [
        DomainClaim.wildcardSubdomain('mastodon.social'),
      ]);
      final b = _Site('B', 'https://other.example/', [
        DomainClaim.baseDomain('mastodon.social'),
      ]);
      final sub = LinkRoutingService.resolve(
        Uri.parse('https://fosstodon.mastodon.social/'),
        [a, b],
      );
      expect((sub as RoutingSingle).site.siteId, 'A');
      final bare = LinkRoutingService.resolve(
        Uri.parse('https://mastodon.social/'),
        [a, b],
      );
      expect((bare as RoutingSingle).site.siteId, 'B');
    });

    test('baseDomain matches multi-part TLD via getBaseDomain', () {
      final a = _Site('A', 'https://www.google.co.uk/', [
        DomainClaim.baseDomain('google.co.uk'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://maps.google.co.uk/place/123'),
        [a],
      );
      expect(r, isA<RoutingSingle>());
      expect((r as RoutingSingle).site.siteId, 'A');
    });

    test('IP host: baseDomain match works for raw IPv4 literal', () {
      final a = _Site('A', 'http://192.168.1.1/', [
        DomainClaim.baseDomain('192.168.1.1'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('http://192.168.1.1/admin'),
        [a],
      );
      expect(r, isA<RoutingSingle>());
    });

    test('tie at top score returns RoutingAmbiguous with all winners', () {
      final a = _Site('A', 'https://reddit.com/', [
        DomainClaim.exactHost('reddit.com'),
      ]);
      final b = _Site('B', 'https://reddit.com/r/x', [
        DomainClaim.exactHost('reddit.com'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://reddit.com/r/flutter'),
        [a, b],
      );
      expect(r, isA<RoutingAmbiguous>());
      final winners = (r as RoutingAmbiguous).sites.map((s) => s.siteId);
      expect(winners, containsAll(['A', 'B']));
    });

    test('no match returns RoutingNone', () {
      final a = _Site('A', 'https://github.com/', [
        DomainClaim.exactHost('github.com'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://example.org/foo'),
        [a],
      );
      expect(r, isA<RoutingNone>());
    });

    test('non-http(s) scheme returns RoutingNone', () {
      final a = _Site('A', 'https://example.org/', [
        DomainClaim.exactHost('example.org'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('javascript:alert(1)'),
        [a],
      );
      expect(r, isA<RoutingNone>());
    });

    test('uppercase host in inbound URL is matched case-insensitively', () {
      final a = _Site('A', 'https://twitter.com/', [
        DomainClaim.exactHost('twitter.com'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://TWITTER.com/user'),
        [a],
      );
      expect(r, isA<RoutingSingle>());
    });

    test('per-site best-claim wins; lower-score claim on same site ignored',
        () {
      final a = _Site('A', 'https://google.com/', [
        DomainClaim.baseDomain('google.com'),
        DomainClaim.exactHost('mail.google.com'),
      ]);
      final b = _Site('B', 'https://drive.google.com/', [
        DomainClaim.baseDomain('google.com'),
      ]);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://mail.google.com/inbox'),
        [a, b],
      );
      expect(r, isA<RoutingSingle>());
      expect((r as RoutingSingle).site.siteId, 'A');
    });
  });

  group('LinkRoutingService.strippedHomeUrl - LIR-009', () {
    test('strips path, query, fragment', () {
      expect(
        LinkRoutingService.strippedHomeUrl(
          Uri.parse('https://example.org/articles/2026/feature?ref=share#top'),
        ),
        'https://example.org/',
      );
    });

    test('preserves explicit non-default port', () {
      expect(
        LinkRoutingService.strippedHomeUrl(
          Uri.parse('http://localhost:8080/dashboard?token=abc'),
        ),
        'http://localhost:8080/',
      );
    });

    test('default ports are NOT serialized (Uri.hasPort is false)', () {
      expect(
        LinkRoutingService.strippedHomeUrl(Uri.parse('https://x.com:443/p')),
        'https://x.com/',
      );
      expect(
        LinkRoutingService.strippedHomeUrl(Uri.parse('http://x.com:80/p')),
        'http://x.com/',
      );
    });

    test('returns null for non-http(s) schemes', () {
      expect(LinkRoutingService.strippedHomeUrl(Uri.parse('ftp://x.com/')),
          isNull);
      expect(LinkRoutingService.strippedHomeUrl(Uri.parse('about:blank')),
          isNull);
      expect(
          LinkRoutingService.strippedHomeUrl(Uri.parse('javascript:void(0)')),
          isNull);
    });

    test('returns null when host is empty', () {
      expect(LinkRoutingService.strippedHomeUrl(Uri.parse('https:///foo')),
          isNull);
    });

    test('IPv4/IPv6 hosts round-trip', () {
      expect(
        LinkRoutingService.strippedHomeUrl(
            Uri.parse('http://192.168.1.1/admin')),
        'http://192.168.1.1/',
      );
      expect(
        LinkRoutingService.strippedHomeUrl(Uri.parse('http://[::1]:9000/x')),
        'http://[::1]:9000/',
      );
    });
  });

  group('LinkRoutingService.parseWebspaceUri - LIR-004', () {
    test('valid open?url=<https> returns inner Uri', () {
      final inner = LinkRoutingService.parseWebspaceUri(
        Uri.parse('webspace://open?url=https%3A%2F%2Ftwitter.com%2Fuser'),
      );
      expect(inner, isNotNull);
      expect(inner!.scheme, 'https');
      expect(inner.host, 'twitter.com');
      expect(inner.path, '/user');
    });

    test('valid open?url=<http> returns inner Uri', () {
      final inner = LinkRoutingService.parseWebspaceUri(
        Uri.parse('webspace://open?url=http%3A%2F%2Fexample.org%2F'),
      );
      expect(inner, isNotNull);
      expect(inner!.scheme, 'http');
    });

    test('non-http(s) inner target returns null', () {
      expect(
        LinkRoutingService.parseWebspaceUri(
            Uri.parse('webspace://open?url=javascript%3Aalert(1)')),
        isNull,
      );
      expect(
        LinkRoutingService.parseWebspaceUri(
            Uri.parse('webspace://open?url=ftp%3A%2F%2Fexample.org%2F')),
        isNull,
      );
    });

    test('missing url= param returns null', () {
      expect(
        LinkRoutingService.parseWebspaceUri(Uri.parse('webspace://open')),
        isNull,
      );
    });

    test('wrong host returns null', () {
      expect(
        LinkRoutingService.parseWebspaceUri(
            Uri.parse('webspace://other?url=https%3A%2F%2Fx.com%2F')),
        isNull,
      );
    });

    test('wrong scheme returns null', () {
      expect(
        LinkRoutingService.parseWebspaceUri(
            Uri.parse('https://open?url=https%3A%2F%2Fx.com%2F')),
        isNull,
      );
    });
  });

  group('LinkRoutingService.claimsToAdoptHost - LIR-010 option 2', () {
    test('emits exactHost + wildcardSubdomain over the base domain', () {
      final claims = LinkRoutingService.claimsToAdoptHost('Forum.Invalid');
      expect(claims, hasLength(2));
      expect(
          claims.first, equals(DomainClaim.exactHost('forum.invalid')));
      expect(claims.last,
          equals(DomainClaim.wildcardSubdomain('forum.invalid')));
    });

    test('subdomain host yields wildcard over the base domain', () {
      final claims =
          LinkRoutingService.claimsToAdoptHost('mail.google.com');
      expect(
          claims,
          equals([
            DomainClaim.exactHost('mail.google.com'),
            DomainClaim.wildcardSubdomain('google.com'),
          ]));
    });

    test('multi-part TLD: wildcard sits over the SLD+ccTLD', () {
      final claims = LinkRoutingService.claimsToAdoptHost('foo.google.co.uk');
      expect(claims, [
        DomainClaim.exactHost('foo.google.co.uk'),
        DomainClaim.wildcardSubdomain('google.co.uk'),
      ]);
    });

    test('empty input returns empty list', () {
      expect(LinkRoutingService.claimsToAdoptHost(''), isEmpty);
      expect(LinkRoutingService.claimsToAdoptHost('   '), isEmpty);
    });
  });

  group('LinkRoutingService.mergeClaims - LIR-010 idempotency', () {
    test('does not duplicate identical claims', () {
      final existing = [
        DomainClaim.exactHost('a.com'),
        DomainClaim.wildcardSubdomain('a.com'),
      ];
      final merged = LinkRoutingService.mergeClaims(
        existing,
        LinkRoutingService.claimsToAdoptHost('a.com'),
      );
      expect(merged, equals(existing));
    });

    test('appends only the new entries', () {
      final existing = [DomainClaim.exactHost('a.com')];
      final merged = LinkRoutingService.mergeClaims(
        existing,
        LinkRoutingService.claimsToAdoptHost('a.com'),
      );
      expect(merged, [
        DomainClaim.exactHost('a.com'),
        DomainClaim.wildcardSubdomain('a.com'),
      ]);
    });

    test('preserves order of existing entries', () {
      final existing = [
        DomainClaim.baseDomain('a.com'),
        DomainClaim.exactHost('b.com'),
      ];
      final merged = LinkRoutingService.mergeClaims(
        existing,
        [DomainClaim.exactHost('c.com'), DomainClaim.exactHost('b.com')],
      );
      expect(merged, [
        DomainClaim.baseDomain('a.com'),
        DomainClaim.exactHost('b.com'),
        DomainClaim.exactHost('c.com'),
      ]);
    });
  });

  group('LinkRoutingService.validateClaims - LIR-003', () {
    test('hijack: claim base equals another site initUrl base', () {
      final github = _Site('github', 'https://github.com/alice',
          [DomainClaim.baseDomain('github.com')]);
      final conflicts = LinkRoutingService.validateClaims(
        'attacker',
        [DomainClaim.exactHost('github.com')],
        [github],
      );
      expect(conflicts, hasLength(1));
      expect(conflicts.single.kind, ClaimConflictKind.hijack);
      expect(conflicts.single.otherSiteId, 'github');
    });

    test('hijack via subdomain claim still triggers (base-domain compare)',
        () {
      final github = _Site('github', 'https://github.com/',
          [DomainClaim.baseDomain('github.com')]);
      final conflicts = LinkRoutingService.validateClaims(
        'attacker',
        [DomainClaim.exactHost('docs.github.com')],
        [github],
      );
      expect(conflicts, hasLength(1));
      expect(conflicts.single.kind, ClaimConflictKind.hijack);
    });

    test('overlap: wildcard vs exact subdomain on different initUrl base', () {
      final wildcard = _Site('wild', 'https://other.example/', [
        DomainClaim.wildcardSubdomain('example.com'),
      ]);
      final conflicts = LinkRoutingService.validateClaims(
        'edited',
        [DomainClaim.exactHost('blog.example.com')],
        [wildcard],
      );
      expect(conflicts, hasLength(1));
      expect(conflicts.single.kind, ClaimConflictKind.overlap);
    });

    test('no conflict when bases differ and claims do not overlap', () {
      final a = _Site('A', 'https://example.org/',
          [DomainClaim.baseDomain('example.org')]);
      final conflicts = LinkRoutingService.validateClaims(
        'edited',
        [DomainClaim.exactHost('twitter.com')],
        [a],
      );
      expect(conflicts, isEmpty);
    });

    test('does not flag the edited site against itself', () {
      final self = _Site('self', 'https://example.org/',
          [DomainClaim.baseDomain('example.org')]);
      final conflicts = LinkRoutingService.validateClaims(
        'self',
        [DomainClaim.exactHost('example.org')],
        [self],
      );
      expect(conflicts, isEmpty);
    });
  });

  group('Three-option dispatch end-to-end shape - LIR-010', () {
    test('option 1 (router default) on single match', () {
      final a = _Site('twitter', 'https://twitter.com/',
          [DomainClaim.exactHost('twitter.com')]);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://twitter.com/anyone'),
        [a],
      );
      expect(r, isA<RoutingSingle>());
    });

    test('option 2 (bind to existing) updates a chosen site idempotently', () {
      final original = _Site('A', 'https://existing.example/',
          [DomainClaim.baseDomain('existing.example')]);
      final inboundHost =
          Uri.parse('https://forum.invalid/thread/42').host;

      final additions = LinkRoutingService.claimsToAdoptHost(inboundHost);
      final firstMerge =
          LinkRoutingService.mergeClaims(original.domainClaims, additions);
      expect(firstMerge.length, original.domainClaims.length + 2);

      final second = LinkRoutingService.mergeClaims(firstMerge, additions);
      expect(second, equals(firstMerge));

      final updated = _Site(original.siteId, original.initUrl, firstMerge);
      final r = LinkRoutingService.resolve(
        Uri.parse('https://api.forum.invalid/v1'),
        [updated],
      );
      expect(r, isA<RoutingSingle>());
      expect((r as RoutingSingle).site.siteId, 'A');
    });

    test('option 3 (create new site, stripped path) yields a sensible home',
        () {
      final url = Uri.parse('https://forum.invalid/thread/42?utm=share#a');
      final home = LinkRoutingService.strippedHomeUrl(url);
      expect(home, 'https://forum.invalid/');

      final newSite = _Site(
        'new',
        home!,
        [DomainClaim.baseDomain('forum.invalid')],
      );
      final follow = LinkRoutingService.resolve(
        Uri.parse('https://www.forum.invalid/'),
        [newSite],
      );
      expect(follow, isA<RoutingSingle>());
    });

    test('no-match without sites: only option 3 is viable', () {
      final r = LinkRoutingService.resolve(
        Uri.parse('https://example.org/foo'),
        const [],
      );
      expect(r, isA<RoutingNone>());
      final home = LinkRoutingService.strippedHomeUrl(
          Uri.parse('https://example.org/foo'));
      expect(home, isNotNull);
    });
  });
}
