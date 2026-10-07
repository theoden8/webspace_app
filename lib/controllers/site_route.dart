import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/web_view_model.dart';

/// A site as the link dispatch engine sees it.
final class SiteRoute implements DispatchableSite {
  const SiteRoute(this.model);

  final WebViewModel model;

  @override
  String get siteId => model.siteId;

  @override
  String get initUrl => model.initUrl;

  @override
  List<DomainClaim> get domainClaims => model.effectiveDomainClaims;

  @override
  bool get incognito => model.incognito;

  @override
  bool get alwaysOpenHome => model.alwaysOpenHome;

  @override
  String get navigationDomain => getNormalizedDomain(model.initUrl);
}
