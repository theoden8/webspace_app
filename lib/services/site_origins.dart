import 'package:meta/meta.dart';
import 'package:webspace/services/link_routing_service.dart';

/// The documents a site's own grants and settings answer for: its address's
/// scheme and a host one of its claims covers (LIR-001), the reading that
/// keeps a link in the site's webview. Any other document a surface of the
/// site shows (a page a link reached in a nested screen, a tab that runs as
/// the site, a popup) is a stranger to it: it is asked for itself and gets
/// nothing the site was granted (PERM-001, SEC-043).
@immutable
final class SiteOrigins {
  SiteOrigins(String initUrl, {required List<DomainClaim> claims})
    : _scheme = Uri.tryParse(initUrl)?.scheme.toLowerCase() ?? '',
      _claims = List.unmodifiable(claims);

  final String _scheme;
  final List<DomainClaim> _claims;

  /// Whether [origin], a document's origin as the platform reports it, is
  /// one of the site's own.
  bool owns(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.scheme.toLowerCase() != _scheme) return false;
    return LinkRoutingService.urlMatchesAnyClaim(uri, claims: _claims);
  }

  /// Where a request from a frame of origin [frame] stands, the top document
  /// being of origin [top].
  Standing standing({required String top, required String frame}) => !owns(top)
      ? Standing.foreign
      : originOf(top) == originOf(frame)
      ? Standing.own
      : Standing.embedded;
}

/// The origin of [url] as `scheme://host[:port]`, the port only where it is
/// not the scheme's own: the one form every grant key and popup uses,
/// whatever shape the platform reported it in. A URL with no host
/// (`about:blank`, `data:`) is its own text, an origin no site owns.
String originOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return uri.hasPort
      ? '${uri.scheme}://$host:${uri.port}'
      : '${uri.scheme}://$host';
}

/// Who asks: the requesting frame's origin, as grant keys and popups name it,
/// and where it [Standing]s toward the site.
typedef Requester = ({String origin, Standing standing});

/// Where a request stands toward the site whose surface it came from.
enum Standing {
  /// The site's own top document, or a frame of its origin: it answers for
  /// the site.
  own,

  /// A frame of another origin inside the site's own top document: the site's
  /// page embedded it, so it takes the site's device-free answers and is
  /// asked for itself for a device (CAM-014 / MIC-016).
  embedded,

  /// A top document the site does not own, or any frame inside one: asked
  /// for itself, and its answers stay with its origin (PERM-001).
  foreign,
}
