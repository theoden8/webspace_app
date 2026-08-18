// Web half of the outbound HTTP seam, used by the design entrypoints.
//
// Mirrors the dart:io half's rule rather than refusing everything:
//
//   DEFAULT  -> the browser's own client, which is the analogue of the direct
//               client dart:io hands back (there, the system proxy applies;
//               here, the browser's does). Favicon fetches, blocklist updates
//               and user-script downloads work, so the app behaves like the
//               app.
//   anything -> blocked. A page cannot honour a per-request HTTP or SOCKS5
//   else       proxy, and quietly going direct is exactly the IP leak the
//              sealed OutboundClient exists to prevent.
//
// Cross-origin responses still obey CORS, so some hosts will fail where they
// succeed natively. That is the browser's rule, not ours.

import 'package:http/http.dart' as http;

import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/proxy.dart';

class DefaultOutboundHttpFactory implements OutboundHttpFactory {
  const DefaultOutboundHttpFactory();

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    final resolved = resolveEffectiveProxy(settings);
    if (resolved.type == ProxyType.DEFAULT) {
      return OutboundClientReady(http.Client());
    }
    return OutboundClientBlocked(
        'a browser cannot honour a ${resolved.type.name} proxy');
  }
}
