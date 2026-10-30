import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/web_extension_grants_engine.dart';
import 'package:webspace/settings/web_extension.dart';

WebExtensionEntry _entry({
  Set<String> hosts = const {},
  Set<String> permissions = const {},
}) => WebExtensionEntry(
  id: WebExtensionId('we-test'),
  name: 'Test',
  version: '1',
  permissions: permissions,
  hosts: hosts,
  everySite: false,
);

final _base = DomainClaim.baseDomain('example.com');

/// Each row: what an extension asked for, what the site claims, and the
/// patterns it is granted.
final _hostRows = <(String, Set<String>, List<DomainClaim>, Set<String>)>[
  (
    'every url on a base domain',
    {'<all_urls>'},
    [_base],
    {'*://*.example.com/*'},
  ),
  (
    'every host on an exact host',
    {'*://*/*'},
    [DomainClaim.exactHost('example.com')],
    {'*://example.com/*'},
  ),
  (
    'https only keeps https',
    {'https://*/*'},
    [_base],
    {'https://*.example.com/*'},
  ),
  (
    'a narrower request stays narrow',
    {'https://mail.example.com/*'},
    [_base],
    {'https://mail.example.com/*'},
  ),
  (
    'a wider request narrows to the host',
    {'*://*.example.com/*'},
    [DomainClaim.exactHost('www.example.com')],
    {'*://www.example.com/*'},
  ),
  (
    'a wildcard claim within the request',
    {'*://*.example.com/*'},
    [DomainClaim.wildcardSubdomain('mail.example.com')],
    {'*://*.mail.example.com/*'},
  ),
  (
    'a wildcard request within the claim',
    {'*://*.mail.example.com/*'},
    [_base],
    {'*://*.mail.example.com/*'},
  ),
  (
    'the path asked for is kept',
    {'https://*.google.com/search*'},
    [DomainClaim.baseDomain('google.com')],
    {'https://*.google.com/search*'},
  ),
  ('another site is not granted', {'https://other.example/*'}, [_base], {}),
  (
    'a host ending in the domain without a dot',
    {'*://*.evilexample.com/*'},
    [_base],
    {},
  ),
  (
    'an exact host ending in a wildcard claim without a dot',
    {'*://evilexample.com/*'},
    [DomainClaim.wildcardSubdomain('example.com')],
    {},
  ),
  (
    'a scheme a page is not reached by',
    {'ws://example.com/*', 'file:///*'},
    [_base],
    {},
  ),
  (
    'a port is never granted',
    {'http://localhost:8080/*'},
    [DomainClaim.exactHost('localhost:8080')],
    {},
  ),
  (
    'case is ignored',
    {'*://*.EXAMPLE.com/*'},
    [_base],
    {'*://*.example.com/*'},
  ),
  (
    'every claim is covered',
    {'<all_urls>'},
    [_base, DomainClaim.exactHost('cdn.other.net')],
    {'*://*.example.com/*', '*://cdn.other.net/*'},
  ),
  ('nothing asked, nothing granted', {}, [_base], {}),
  ('a site with no claims gets nothing', {'<all_urls>'}, [], {}),
];

typedef _Planner =
    ExtensionGrants Function(
      WebExtensionEntry entry, {
      required List<DomainClaim> claims,
    });

List<String> _hostMisses(_Planner plan) => [
  for (final (label, hosts, claims, want) in _hostRows)
    if (!_sameSet(
      plan(_entry(hosts: hosts), claims: claims).matchPatterns,
      as: want,
    ))
      label,
];

bool _sameSet(Set<String> a, {required Set<String> as}) =>
    a.length == as.length && a.containsAll(as);

/// Planted mistake: `<all_urls>` handed through as asked.
ExtensionGrants _allUrlsPassedThrough(
  WebExtensionEntry entry, {
  required List<DomainClaim> claims,
}) {
  final real = planExtensionGrants(entry, claims: claims);
  return (
    matchPatterns: {
      ...real.matchPatterns,
      if (entry.hosts.contains('<all_urls>')) '<all_urls>',
    },
    permissions: real.permissions,
  );
}

/// Planted mistake: a host taken as within a domain when it merely ends in
/// it, with no dot between.
ExtensionGrants _withoutDotBoundary(
  WebExtensionEntry entry, {
  required List<DomainClaim> claims,
}) {
  final real = planExtensionGrants(entry, claims: claims);
  return (
    matchPatterns: {
      ...real.matchPatterns,
      for (final requested in entry.hosts.map(parseMatchPattern).nonNulls)
        if (requested.host != '*' &&
            claims.any((c) => requested.host.endsWith(c.value)))
          requested.toString(),
    },
    permissions: real.permissions,
  );
}

/// Planted mistake: native messaging granted when asked for.
ExtensionGrants _nativeMessagingGranted(
  WebExtensionEntry entry, {
  required List<DomainClaim> claims,
}) {
  final real = planExtensionGrants(entry, claims: claims);
  return (
    matchPatterns: real.matchPatterns,
    permissions: {
      ...real.permissions,
      if (entry.permissions.contains('nativeMessaging')) 'nativeMessaging',
    },
  );
}

const _askedPermissions = {
  'storage',
  'tabs',
  'scripting',
  'nativeMessaging',
  'debugger',
  'downloads',
};
const _grantedPermissions = {'storage', 'tabs', 'scripting'};

bool _permissionsHold(_Planner plan) => _sameSet(
  plan(_entry(permissions: _askedPermissions), claims: [_base]).permissions,
  as: _grantedPermissions,
);

void main() {
  group(
    'WEBEXT-014 an extension\'s hosts are what it asked for within the site',
    () {
      test(
        'every host row grants the overlap of what was asked and claimed',
        () {
          expect(_hostMisses(planExtensionGrants), isEmpty);
        },
      );

      test('a site claims its hosts as match patterns, ports never', () {
        expect(
          siteMatchPatterns([
            DomainClaim.exactHost('example.com'),
            DomainClaim.exactHost('localhost:8080'),
            DomainClaim.exactHost('[::1]:8080'),
            DomainClaim.wildcardSubdomain('example.org'),
            DomainClaim.baseDomain('mail.example.net'),
          ]),
          {'*://example.com/*', '*://*.example.org/*', '*://*.example.net/*'},
        );
        expect(siteMatchPatterns(const []), isEmpty);
      });

      test('a pattern a page cannot fall under is not parsed', () {
        for (final pattern in [
          'ws://example.com/*',
          'file:///*',
          'https://example.com',
          'https://*example.com/*',
          'https://exa*mple.com/*',
          'https://*./*',
          'not a pattern',
        ]) {
          expect(parseMatchPattern(pattern), isNull, reason: pattern);
        }
        expect(parseMatchPattern('<all_urls>').toString(), '*://*/*');
      });
    },
  );

  group(
    'WEBEXT-015 an extension holds only the permissions the app allows',
    () {
      test('only the permissions an extension may hold are granted', () {
        expect(_permissionsHold(planExtensionGrants), isTrue);
      });
    },
  );

  group('WEBEXT-014 WEBEXT-015 planted mistakes are caught', () {
    test('<all_urls> handed through misses a row', () {
      expect(_hostMisses(_allUrlsPassedThrough), isNotEmpty);
    });

    test('a domain matched without a dot boundary misses a row', () {
      expect(_hostMisses(_withoutDotBoundary), isNotEmpty);
    });

    test('native messaging granted breaks the permission check', () {
      expect(_permissionsHold(_nativeMessagingGranted), isFalse);
    });
  });
}
