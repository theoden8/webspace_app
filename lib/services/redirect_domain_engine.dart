import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/url_host.dart';

/// A domain the site's first settled page could add to its existing claims.
/// The usual claim validator keeps this offer from taking another site's links.
DomainClaim? redirectDomainClaim(
  RoutableSite site, {
  required Uri resolvedUrl,
  required List<RoutableSite> sites,
}) {
  final home = Uri.tryParse(site.initUrl);
  if (Host.ofWebUrl(home?.toString()) == null ||
      Host.ofWebUrl(resolvedUrl.toString()) == null ||
      LinkRoutingService.hostAuthority(home!) ==
          LinkRoutingService.hostAuthority(resolvedUrl) ||
      LinkRoutingService.urlMatchesAnyClaim(
        resolvedUrl,
        claims: site.domainClaims,
      )) {
    return null;
  }
  final claim = resolvedUrl.hasPort
      ? DomainClaim.exactHost(LinkRoutingService.hostAuthority(resolvedUrl))
      : DomainClaim.baseDomain(getBaseDomain(resolvedUrl.toString()));
  if (LinkRoutingService.validateClaims(
    site.siteId,
    editedClaims: [claim],
    others: sites,
  ).isNotEmpty) {
    return null;
  }
  return claim;
}
