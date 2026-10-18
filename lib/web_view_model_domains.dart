import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/web_view_model.dart';

/// The site's declared domains, including the implicit home-domain claim.
extension WebViewModelDomains on WebViewModel {
  /// View used by the resolver: the explicit `domainClaims` if the user has
  /// set them, otherwise what [initUrl] claims by itself (LIR-001).
  List<DomainClaim> get effectiveDomainClaims {
    final explicit = domainClaims;
    return explicit != null && explicit.isNotEmpty
        ? explicit
        : DomainClaim.implicitFor(initUrl);
  }

  /// True when [url] is covered by one of this site's domain claims. Every
  /// external-link mode keeps claimed cross-domain links in a nested webview;
  /// only unclaimed ones go to the browser or are blocked.
  bool matchesSiteClaim(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        LinkRoutingService.urlMatchesAnyClaim(
          uri,
          claims: effectiveDomainClaims,
        );
  }
}
