import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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

/// Default factory backed by `dart:io`'s [HttpClient].
///
/// - DEFAULT  → direct client (system proxy, if any, is honored by dart:io)
/// - HTTP/HTTPS → [HttpClient.findProxy] override pointing at the host:port
/// - SOCKS5  → [OutboundClientBlocked] (dart:io has no SOCKS5 support;
///            falling back to direct would leak the IP, so fail-closed)
class DefaultOutboundHttpFactory implements OutboundHttpFactory {
  const DefaultOutboundHttpFactory();

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    switch (settings.type) {
      case ProxyType.DEFAULT:
        return OutboundClientReady(http.Client());

      case ProxyType.HTTP:
      case ProxyType.HTTPS:
        final addr = settings.address;
        if (addr == null || addr.isEmpty) {
          return OutboundClientReady(http.Client());
        }
        final hostPort = parseHostPort(addr);
        if (hostPort == null) {
          return OutboundClientBlocked(
            'Invalid proxy address "$addr". Outbound request blocked to '
            'avoid leaking the device IP via a direct fallback.',
          );
        }
        final inner = HttpClient();
        inner.findProxy = (uri) {
          final host = uri.host.toLowerCase();
          if (_isLocalhost(host)) return 'DIRECT';
          return 'PROXY $addr';
        };
        if (settings.hasCredentials) {
          inner.addProxyCredentials(
            hostPort.$1,
            hostPort.$2,
            '',
            HttpClientBasicCredentials(settings.username!, settings.password!),
          );
        }
        return OutboundClientReady(IOClient(inner));

      case ProxyType.SOCKS5:
        return const OutboundClientBlocked(
          'SOCKS5 is configured. Dart-side HTTP cannot tunnel through SOCKS5, '
          'so the request was blocked to avoid leaking the device IP.',
        );
    }
  }
}

/// Parse `host:port`. Returns null on invalid input.
@visibleForTesting
(String, int)? parseHostPort(String addr) {
  final i = addr.lastIndexOf(':');
  if (i <= 0 || i == addr.length - 1) return null;
  final host = addr.substring(0, i);
  final port = int.tryParse(addr.substring(i + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (host, port);
}

bool _isLocalhost(String host) {
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

OutboundHttpFactory _factory = const DefaultOutboundHttpFactory();

/// Global outbound HTTP factory. Use this from every Dart-side HTTP call
/// that can carry user-identifying traffic.
OutboundHttpFactory get outboundHttp => _factory;

/// Replace the global factory. Intended for tests.
@visibleForTesting
set outboundHttp(OutboundHttpFactory f) => _factory = f;

/// Restore the default factory. Call from `tearDown` in tests.
@visibleForTesting
void resetOutboundHttp() => _factory = const DefaultOutboundHttpFactory();
