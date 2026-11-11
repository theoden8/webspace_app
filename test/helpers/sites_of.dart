import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// The sites a test holds, found by id as the runtime finds them.
final class SitesOf implements SitesById {
  SitesOf(this._sites);

  final Iterable<WebViewModel> _sites;

  @override
  WebViewModel siteOf(SiteId id) => _sites.firstWhere((m) => m.siteId == id);
}
