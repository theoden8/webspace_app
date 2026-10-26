/// What an extension may reach on one site (WEBEXT-005, WEBEXT-007): the
/// overlap of the hosts it asked for with the hosts the site claims, and the
/// permissions it asked for that an extension may hold here. Whatever an
/// extension asks for later is answered with these and nothing more.
library;

import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/url_host.dart' show getBaseDomain;
import 'package:webspace/settings/web_extension.dart';

/// What one extension may reach on one site.
typedef ExtensionGrants = ({
  Set<String> matchPatterns,
  Set<String> permissions,
});

/// The API permissions an extension may hold. Everything else is refused,
/// `nativeMessaging` among them: no app API is exposed to an extension.
const Set<String> grantablePermissions = {
  'activeTab',
  'alarms',
  'clipboardWrite',
  'contextMenus',
  'cookies',
  'declarativeNetRequest',
  'declarativeNetRequestFeedback',
  'declarativeNetRequestWithHostAccess',
  'menus',
  'scripting',
  'storage',
  'tabs',
  'unlimitedStorage',
  'webNavigation',
  'webRequest',
};

/// What [entry] may reach on a site claiming [claims].
ExtensionGrants planExtensionGrants(
  WebExtensionEntry entry, {
  required List<DomainClaim> claims,
}) {
  final site = siteMatchPatterns(claims).map(parseMatchPattern).nonNulls;
  final granted = <String>{};
  for (final requested in entry.hosts.map(parseMatchPattern).nonNulls) {
    for (final claimed in site) {
      if (_overlap(requested, claimed: claimed) case final pattern?) {
        granted.add(pattern.toString());
      }
    }
  }
  return (
    matchPatterns: granted,
    permissions: entry.permissions.intersection(grantablePermissions),
  );
}

/// The match patterns [claims] cover: an exact host is that host, a base
/// domain is the domain and its subdomains. A wildcard claim covers the
/// subdomains of a host, which a match pattern cannot say without the host
/// itself, so its pattern takes the bare host too. A claim with a port
/// covers nothing: a match pattern does not name ports.
Set<String> siteMatchPatterns(List<DomainClaim> claims) => {
  for (final claim in claims)
    if (claim.value.isNotEmpty)
      ?switch (claim.kind) {
        DomainClaimKind.exactHost =>
          _hasPort(claim.value) ? null : '*://${claim.value}/*',
        DomainClaimKind.wildcardSubdomain => '*://*.${claim.value}/*',
        DomainClaimKind.baseDomain => '*://*.${getBaseDomain(claim.value)}/*',
      },
};

bool _hasPort(String host) => host.startsWith('[')
    ? host.substring(host.indexOf(']') + 1).startsWith(':')
    : host.contains(':');

/// A match pattern over http and https, the only schemes a site's pages
/// are reached by.
final class ExtensionMatchPattern {
  const ExtensionMatchPattern({
    required this.scheme,
    required this.host,
    required this.path,
  });

  /// `*` (http and https), `http` or `https`.
  final String scheme;

  /// `*`, `*.` and a domain (the domain and its subdomains), or a host.
  final String host;

  /// Starts with `/`; `*` matches any run of characters.
  final String path;

  @override
  String toString() => '$scheme://$host$path';
}

final _matchPatternSyntax = RegExp(r'^(\*|https?)://([^/:]+)(/.*)$');

/// [pattern] as a match pattern a site's page can fall under, or null for
/// one it cannot: another scheme, a port, or not a match pattern.
ExtensionMatchPattern? parseMatchPattern(String pattern) {
  if (pattern == '<all_urls>') {
    return const ExtensionMatchPattern(scheme: '*', host: '*', path: '/*');
  }
  final m = _matchPatternSyntax.firstMatch(pattern.toLowerCase());
  if (m == null) return null;
  final host = m[2]!;
  final body = host.startsWith('*.') ? host.substring(2) : host;
  if (host != '*' && (body.isEmpty || body.contains('*'))) return null;
  return ExtensionMatchPattern(scheme: m[1]!, host: host, path: m[3]!);
}

/// The pages both [requested] and [claimed] name, as one pattern, or null
/// when they share none.
ExtensionMatchPattern? _overlap(
  ExtensionMatchPattern requested, {
  required ExtensionMatchPattern claimed,
}) {
  final scheme = switch ((requested.scheme, claimed.scheme)) {
    ('*', final s) || (final s, '*') => s,
    (final a, final b) when a == b => a,
    _ => null,
  };
  final host = _hostOverlap(requested.host, claimed: claimed.host);
  if (scheme == null || host == null) return null;
  return ExtensionMatchPattern(
    scheme: scheme,
    host: host,
    path: requested.path,
  );
}

String? _hostOverlap(String requested, {required String claimed}) {
  if (requested == '*') return claimed;
  if (claimed == '*') return requested;
  final requestedDomain = _domainOf(requested);
  final claimedDomain = _domainOf(claimed);
  return switch ((requestedDomain, claimedDomain)) {
    (null, null) => requested == claimed ? requested : null,
    (null, final d?) => _within(requested, domain: d) ? requested : null,
    (final d?, null) => _within(claimed, domain: d) ? claimed : null,
    (final r?, final c?) =>
      _within(r, domain: c)
          ? requested
          : _within(c, domain: r)
          ? claimed
          : null,
  };
}

/// The domain a `*.` host covers, or null for a single host.
String? _domainOf(String host) =>
    host.startsWith('*.') ? host.substring(2) : null;

/// Whether [host] is [domain] or one of its subdomains, on a dot boundary.
bool _within(String host, {required String domain}) =>
    host == domain || host.endsWith('.$domain');
