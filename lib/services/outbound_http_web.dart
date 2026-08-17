// Web half of the outbound HTTP seam. The app never ships for web; this exists
// so the design gallery can compile screens that transitively import the seam.
// Every request is refused rather than silently sent direct, which is the same
// rule the dart:io half applies when it cannot honour a proxy.

import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/proxy.dart';

class DefaultOutboundHttpFactory implements OutboundHttpFactory {
  const DefaultOutboundHttpFactory();

  @override
  OutboundClient clientFor(UserProxySettings settings) =>
      const OutboundClientBlocked('dart:io HTTP is unavailable on web');
}
