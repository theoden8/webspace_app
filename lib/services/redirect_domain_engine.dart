import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/url_host.dart';

/// A claim that preserves routing when an externally handled URL becomes home.
/// The usual claim validator keeps this offer from taking another site's links.
DomainClaim? redirectDomainClaim(
  RoutableSite site, {
  required Uri resolvedUrl,
  required NavigationDecision navigationDecision,
  required List<RoutableSite> sites,
}) {
  final leavesSite = switch (navigationDecision) {
    NavigationDecision.blockOpenNested ||
    NavigationDecision.blockOpenExternal ||
    NavigationDecision.blockOutbound => true,
    NavigationDecision.allow ||
    NavigationDecision.blockSilent ||
    NavigationDecision.blockSuppressed => false,
  };
  final home = Uri.tryParse(site.initUrl);
  if (!leavesSite ||
      Host.ofWebUrl(home?.toString()) == null ||
      Host.ofWebUrl(resolvedUrl.toString()) == null) {
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
