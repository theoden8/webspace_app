// Platform-neutral half of the outbound HTTP seam: the proxy resolution rule,
// the sealed client result, the factory contract and the DNT wrapper. Kept free
// of dart:io so screens that transitively reach this seam still compile for the
// web target (see tool/design_gallery/CLAUDE.md); the dart:io implementation
// lives in outbound_http_io.dart.

import 'package:http/http.dart' as http;

import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// Resolve the effective proxy for a per-site outbound call.
///
/// When the per-site [ProxyType] is [ProxyType.DEFAULT], the call falls
/// through to the **global** outbound proxy ([GlobalOutboundProxy.current]).
/// This matches user intent: "I configured a global proxy (e.g. Tor); a
/// site I haven't customized should also go through it." When the per-site
/// type is anything else, the site's own settings win.
///
/// Apply this at every per-site outbound seam — Dart-side HTTP *and* the
/// native webview proxy — so a site set to DEFAULT doesn't silently bypass
/// the global proxy in either direction.
UserProxySettings resolveEffectiveProxy(UserProxySettings perSite) {
  if (perSite.type == ProxyType.DEFAULT) {
    return GlobalOutboundProxy.current;
  }
  return perSite;
}

/// Result of asking the [OutboundHttpFactory] to build a client honoring a
/// given [UserProxySettings]. Sealed so callers must handle both cases —
/// silently falling back to a direct client would leak the user's IP.
sealed class OutboundClient {
  const OutboundClient();
}

/// A live [http.Client] honoring the requested proxy. Caller MUST close it.
class OutboundClientReady extends OutboundClient {
  final http.Client client;
  const OutboundClientReady(this.client);
}

/// Wrap [inner] so every outgoing request carries the always-on `DNT: 1`
/// and `Sec-GPC: 1` headers. The privacy posture of this app is "do not
/// track me": every Dart-side outbound seam (downloads, user-script
/// fetches, blocklist updates, favicon probes, …) must advertise that
/// preference on the wire. Existing headers win — callers that
/// explicitly set `DNT`/`Sec-GPC` for a test or odd-server probe keep
/// their value.
class DoNotTrackClient extends http.BaseClient {
  final http.Client _inner;
  DoNotTrackClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.putIfAbsent('DNT', () => '1');
    request.headers.putIfAbsent('Sec-GPC', () => '1');
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// The configured proxy cannot be honored from Dart-side HTTP. The caller
/// MUST abort the request — falling back to a direct connection would leak
/// the user's IP, defeating the proxy the user explicitly chose.
class OutboundClientBlocked extends OutboundClient {
  final String reason;
  const OutboundClientBlocked(this.reason);
}

/// Contract for producing an [http.Client] that routes through a given
/// [UserProxySettings]. This is the seam that lets every Dart-side outbound
/// call honor a per-site or app-global proxy.
///
/// Tests replace [outboundHttp] with a fake to assert what proxy each call
/// site requested without performing real I/O.
abstract class OutboundHttpFactory {
  OutboundClient clientFor(UserProxySettings settings);
}

/// Parse `host:port`. Returns null on invalid input. Used by the dart:io
/// factory as well as tests, so it cannot be test-only.
(String, int)? parseHostPort(String addr) {
  final i = addr.lastIndexOf(':');
  if (i <= 0 || i == addr.length - 1) return null;
  final host = addr.substring(0, i);
  final port = int.tryParse(addr.substring(i + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (host, port);
}
