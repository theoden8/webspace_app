import 'package:webspace/web_view_model.dart' show extractDomain, getBaseDomain;

enum DomainClaimKind { exactHost, wildcardSubdomain, baseDomain }

class DomainClaim {
  final DomainClaimKind kind;
  final String value;

  const DomainClaim._raw(this.kind, this.value);

  factory DomainClaim(DomainClaimKind kind, String value) =>
      DomainClaim._raw(kind, _canon(value));

  factory DomainClaim.exactHost(String host) =>
      DomainClaim(DomainClaimKind.exactHost, host);

  factory DomainClaim.wildcardSubdomain(String host) =>
      DomainClaim(DomainClaimKind.wildcardSubdomain, host);

  factory DomainClaim.baseDomain(String host) =>
      DomainClaim(DomainClaimKind.baseDomain, host);

  static String _canon(String s) {
    var v = s.trim().toLowerCase();
    if (v.isEmpty) return v;
    if (v.contains('://')) {
      v = Uri.tryParse(v)?.host ?? v;
    }
    if (v.startsWith('*.')) v = v.substring(2);
    final colon = v.indexOf(':');
    if (colon > 0) v = v.substring(0, colon);
    if (v.startsWith('[') && v.contains(']')) {
      v = v.substring(1, v.indexOf(']'));
    }
    return v;
  }

  Map<String, dynamic> toJson() => {'kind': kind.name, 'value': value};

  factory DomainClaim.fromJson(Map<String, dynamic> json) => DomainClaim(
        DomainClaimKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => DomainClaimKind.baseDomain,
        ),
        json['value'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is DomainClaim && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => '${kind.name}:$value';
}

abstract class RoutableSite {
  String get siteId;
  String get initUrl;
  List<DomainClaim> get domainClaims;
}

sealed class RoutingMatch {
  const RoutingMatch();
}

class RoutingSingle extends RoutingMatch {
  final RoutableSite site;
  const RoutingSingle(this.site);
}

class RoutingAmbiguous extends RoutingMatch {
  final List<RoutableSite> sites;
  const RoutingAmbiguous(this.sites);
}

class RoutingNone extends RoutingMatch {
  const RoutingNone();
}

enum ClaimConflictKind { hijack, overlap }

class ClaimConflict {
  final DomainClaim claim;
  final String otherSiteId;
  final ClaimConflictKind kind;

  const ClaimConflict({
    required this.claim,
    required this.otherSiteId,
    required this.kind,
  });

  @override
  String toString() =>
      'ClaimConflict(${kind.name}, claim=$claim, other=$otherSiteId)';
}

class LinkRoutingService {
  LinkRoutingService._();

  static const int _scoreExactHost = 300;
  static const int _scoreWildcardSubdomain = 200;
  static const int _scoreBaseDomain = 100;

  static int _score(DomainClaim claim, String host, String base) {
    switch (claim.kind) {
      case DomainClaimKind.exactHost:
        return claim.value == host ? _scoreExactHost : 0;
      case DomainClaimKind.wildcardSubdomain:
        return host.endsWith('.${claim.value}') ? _scoreWildcardSubdomain : 0;
      case DomainClaimKind.baseDomain:
        return getBaseDomain(claim.value) == base ? _scoreBaseDomain : 0;
    }
  }

  static RoutingMatch resolve(Uri url, List<RoutableSite> sites) {
    if (url.scheme != 'http' && url.scheme != 'https') {
      return const RoutingNone();
    }
    if (url.host.isEmpty) return const RoutingNone();
    final host = url.host.toLowerCase();
    final base = getBaseDomain(host);
    int best = 0;
    final winners = <RoutableSite>[];
    for (final site in sites) {
      int siteBest = 0;
      for (final claim in site.domainClaims) {
        final s = _score(claim, host, base);
        if (s > siteBest) siteBest = s;
      }
      if (siteBest == 0) continue;
      if (siteBest > best) {
        best = siteBest;
        winners
          ..clear()
          ..add(site);
      } else if (siteBest == best) {
        winners.add(site);
      }
    }
    if (winners.isEmpty) return const RoutingNone();
    if (winners.length == 1) return RoutingSingle(winners.single);
    return RoutingAmbiguous(List.unmodifiable(winners));
  }

  static String? strippedHomeUrl(Uri url) {
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    if (url.host.isEmpty) return null;
    final host = url.host.contains(':') ? '[${url.host}]' : url.host;
    final port = url.hasPort ? ':${url.port}' : '';
    return '${url.scheme}://$host$port/';
  }

  static Uri? parseWebspaceUri(Uri raw) {
    if (raw.scheme.toLowerCase() != 'webspace') return null;
    final host = raw.host.toLowerCase();
    final path = raw.path;
    final isOpen = host == 'open' ||
        (host.isEmpty && (path == 'open' || path == '/open'));
    if (!isOpen) return null;
    final encoded = raw.queryParameters['url'];
    if (encoded == null || encoded.isEmpty) return null;
    final inner = Uri.tryParse(encoded);
    if (inner == null) return null;
    if (inner.scheme != 'http' && inner.scheme != 'https') return null;
    if (inner.host.isEmpty) return null;
    return inner;
  }

  static List<DomainClaim> claimsToAdoptHost(String host) {
    final h = DomainClaim._canon(host);
    if (h.isEmpty) return const [];
    final base = getBaseDomain(h);
    final out = <DomainClaim>[DomainClaim.exactHost(h)];
    if (base.isNotEmpty) {
      out.add(DomainClaim.wildcardSubdomain(base));
    }
    return out;
  }

  static List<DomainClaim> mergeClaims(
    List<DomainClaim> existing,
    List<DomainClaim> additions,
  ) {
    final seen = <DomainClaim>{...existing};
    final out = <DomainClaim>[...existing];
    for (final c in additions) {
      if (seen.add(c)) out.add(c);
    }
    return out;
  }

  static List<ClaimConflict> validateClaims(
    String editedSiteId,
    List<DomainClaim> editedClaims,
    List<RoutableSite> others,
  ) {
    final out = <ClaimConflict>[];
    for (final claim in editedClaims) {
      final claimBase = getBaseDomain(claim.value);
      if (claimBase.isEmpty) continue;
      for (final other in others) {
        if (other.siteId == editedSiteId) continue;
        final otherBase = getBaseDomain(extractDomain(other.initUrl));
        if (otherBase.isEmpty) continue;
        if (otherBase == claimBase) {
          out.add(ClaimConflict(
            claim: claim,
            otherSiteId: other.siteId,
            kind: ClaimConflictKind.hijack,
          ));
          continue;
        }
        for (final otherClaim in other.domainClaims) {
          if (_claimsOverlap(claim, otherClaim)) {
            out.add(ClaimConflict(
              claim: claim,
              otherSiteId: other.siteId,
              kind: ClaimConflictKind.overlap,
            ));
            break;
          }
        }
      }
    }
    return out;
  }

  static bool _claimsOverlap(DomainClaim a, DomainClaim b) {
    if (a == b) return true;
    final av = a.value;
    final bv = b.value;
    if (a.kind == DomainClaimKind.exactHost &&
        b.kind == DomainClaimKind.wildcardSubdomain) {
      return av.endsWith('.$bv');
    }
    if (b.kind == DomainClaimKind.exactHost &&
        a.kind == DomainClaimKind.wildcardSubdomain) {
      return bv.endsWith('.$av');
    }
    return false;
  }
}

