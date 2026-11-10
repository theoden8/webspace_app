// dart:io half of the outbound HTTP seam. The native proxy, SOCKS5 and
// certificate-pinning behaviour must not vary because the web target exists.

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/trusted_hosts_x509.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/socks_connect.dart';
import 'package:webspace/services/url_host.dart';

/// Default factory backed by `dart:io`'s [HttpClient].
///
/// - DEFAULT  → direct client (system proxy, if any, is honored by dart:io),
///            which never connects to an onion service (LEAK-016)
/// - HTTP     → [HttpClient.findProxy] override pointing at the host:port
/// - HTTPS    → the same, over a TLS session to the proxy: `findProxy` alone
///            makes dart:io write `CONNECT` and `Proxy-Authorization` on a
///            plain socket before any handshake (LEAK-008)
/// - SOCKS5  → connection factory tunnels every request via the
///            [socks5_proxy] package; the SOCKS5 server resolves the
///            destination hostname, so the user's local resolver never
///            sees it (matches Tor's `dns_proxy` semantics).
class DefaultOutboundHttpFactory implements OutboundHttpFactory {
  const DefaultOutboundHttpFactory();

  @override
  OutboundClient clientFor(
    ProxyRoute route, {
    BodyEncoding encoding = BodyEncoding.decoded,
  }) =>
      _clientFor(route, encoding: encoding);

  OutboundClient _pageSteeredBuild(ProxyRoute route,
      {String? allowPrivateHost}) {
    // Under a proxy the destination name is resolved at the far end, so the
    // proxied client applies and the local resolve-and-pin would describe a
    // network the request never traverses (classifyOutboundTarget); under
    // DEFAULT the direct client resolves the host once and pins to the judged
    // address. Either result is wrapped so a page cannot reach a private
    // *literal* on any route: a name travels to the proxy and is resolved
    // there, but `http://127.0.0.1/` is refused whether or not a proxy carries
    // it, so a proxy never becomes a path to the loopback the pin guards.
    final OutboundClient base = route.type != ProxyType.DEFAULT
        ? _clientFor(route, encoding: BodyEncoding.decoded, pageSteered: true)
        : OutboundClientReady(IOClient(
            _pageSteeredDirectClient(allowPrivateHost: allowPrivateHost)));
    if (base is OutboundClientReady) {
      return OutboundClientReady(_PageSteeredLiteralGuard(base.client,
          allowPrivateHost: allowPrivateHost?.toLowerCase(),
          resolvesLocally: route.type == ProxyType.DEFAULT));
    }
    return base;
  }

  OutboundClient _clientFor(
    UserProxySettings settings, {
    required BodyEncoding encoding,
    bool pageSteered = false,
  }) {
    switch (settings.type) {
      case ProxyType.DEFAULT:
        return OutboundClientReady(
            IOClient(_directHttpClient(encoding: encoding)));

      case ProxyType.HTTP:
      case ProxyType.HTTPS:
        final addr = settings.address;
        if (addr == null || addr.isEmpty) {
          return OutboundClientBlocked(
            'Proxy type is set but the address is empty. Outbound request '
            'blocked to avoid leaking the device IP via a direct fallback.',
          );
        }
        final hostPort = parseHostPort(addr);
        if (hostPort == null) {
          return OutboundClientBlocked(
            'Invalid proxy address "$addr". Outbound request blocked to '
            'avoid leaking the device IP via a direct fallback.',
          );
        }
        return _httpProxyClient(
          settings,
          addr: addr,
          hostPort: hostPort,
          tls: settings.type == ProxyType.HTTPS,
          encoding: encoding,
          pageSteered: pageSteered,
        );

      case ProxyType.TOR:
        // TOR carries no address of its own; it expands at use-time into
        // the loopback SOCKS5 endpoint plus this caller's isolation tag.
        // While the runtime is not up the only safe answer is to block:
        // falling through to SOCKS5-with-no-address or to a direct client
        // would put the request on the device IP, which is the exact thing
        // the user turned Tor on to prevent (TOR-008).
        return switch (expandTorProxy(settings)) {
          TorRouteUp(:final socks) =>
            _clientFor(socks, encoding: encoding, pageSteered: pageSteered),
          TorRouteBlocked(:final reason) => OutboundClientBlocked(
              '$reason Outbound request blocked to avoid leaking the device '
              'IP via a direct fallback.',
            ),
        };

      case ProxyType.SAVED:
      case ProxyType.GATEWAY:
        // What a route still names of the proxy library did not resolve.
        return const OutboundClientBlocked(
          'The saved proxy, gateway or credentials this setting names no '
          'longer exist or do not fit together. Outbound request blocked to '
          'avoid leaking the device IP via a direct fallback.',
        );

      case ProxyType.SOCKS5:
        final addr = settings.address;
        if (addr == null || addr.isEmpty) {
          return OutboundClientBlocked(
            'SOCKS5 proxy type is set but the address is empty. Outbound '
            'request blocked to avoid leaking the device IP via a direct '
            'fallback.',
          );
        }
        final hostPort = parseHostPort(addr);
        if (hostPort == null) {
          return OutboundClientBlocked(
            'Invalid SOCKS5 proxy address "$addr". Outbound request blocked '
            'to avoid leaking the device IP via a direct fallback.',
          );
        }
        return _socks5Client(
          host: hostPort.$1,
          port: hostPort.$2,
          username: settings.hasCredentials ? settings.username : null,
          password: settings.hasCredentials ? settings.password : null,
          encoding: encoding,
        );
    }
  }

  /// Construct an [HttpClient] whose `badCertificateCallback` accepts a
  /// cert iff the user has previously trusted (host, port, sha256) via
  /// [TrustedHostsService]. Used everywhere this factory makes a client
  /// so a self-signed site the user already trusted in the webview also
  /// works for Dart-side fetches (favicon probes, downloads, …) — the
  /// alternative was a `HandshakeException: CERTIFICATE_VERIFY_FAILED`
  /// the moment any non-webview code touched the same site.
  static HttpClient _newHttpClient({required BodyEncoding encoding}) {
    final client = HttpClient()
      ..autoUncompress = switch (encoding) {
        BodyEncoding.decoded => true,
        BodyEncoding.asSent => false,
      };
    client.badCertificateCallback = (cert, host, port) =>
        _isTrustedBadCert(cert, host: host, port: port);
    return client;
  }

  /// A client no proxy carries. It refuses an onion service before anything
  /// resolves it: only Tor does, so a direct connection would only hand the
  /// name to the device's resolver (LEAK-016). Asked per connection, so a
  /// redirect to one is refused too. Otherwise it connects as dart:io would
  /// without a factory.
  static HttpClient _directHttpClient({required BodyEncoding encoding}) {
    final client = _newHttpClient(encoding: encoding);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final host = Host(uri.host);
      if (host.isOnion) return Future.error(OnionNeedsProxyFailure(host));
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      return uri.scheme == 'https'
          ? SecureSocket.startConnect(
              uri.host,
              uri.port,
              onBadCertificate: (cert) =>
                  _isTrustedBadCert(cert, host: uri.host, port: uri.port),
            )
          : Socket.startConnect(uri.host, uri.port);
    };
    return client;
  }

  /// A direct client for a URL a loaded page can steer (SEC-049). Every
  /// connection it makes — the first and each redirect hop, since dart:io asks
  /// the connection factory per connection — judges the destination as it
  /// connects, closing the window where a name that passed a pre-flight range
  /// check rebinds into a private range before the client's own connect (the
  /// residual [classifyOutboundTarget] documents).
  ///
  /// Both schemes pin the same way: [hostLookup] (the app's one resolver)
  /// resolves the host once, the address is judged, and the socket connects only
  /// to a judged address — never a name re-resolved at connect time. HTTPS runs
  /// TLS over that pinned socket with SNI and certificate verification against
  /// the hostname, so the TLS session is bound to the name while the bytes go
  /// only to the judged address: no byte, not even the ClientHello, reaches an
  /// address the judge did not accept. [allowPrivateHost] is the one host whose
  /// own private address is acceptable (a page-linked resource's document host,
  /// so a LAN site still serves its own icon).
  static HttpClient _pageSteeredDirectClient({String? allowPrivateHost}) {
    final client = _newHttpClient(encoding: BodyEncoding.decoded);
    // Route by the same env-proxy source the per-request guard reads, so the two
    // agree on whether a proxy carries the request (M1). In production this is
    // dart:io's own findProxyFromEnvironment, i.e. the default; a test swaps it.
    client.findProxy = _pageSteeredFindProxy;
    final allow = allowPrivateHost?.toLowerCase();
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = Host(uri.host);
      if (host.isOnion) throw OnionNeedsProxyFailure(host);
      final allowed = allow != null && uri.host.toLowerCase() == allow;
      // Judge the destination's local resolution before connecting, whichever
      // way it is carried. The old pre-flight classify judged a DEFAULT route's
      // local resolution even when the OS had a proxy set, so an OS proxy must
      // not become a way to reach a private address unjudged. The throw happens
      // here, before any socket opens.
      final judged = await _judgedAddress(uri.host, allowPrivate: allowed);
      // An OS proxy carries the request: it connects to the far end, so hand
      // dart:io the socket to the proxy as [_directHttpClient] does. The local
      // resolution is judged above; the proxy resolves its own.
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      if (uri.scheme == 'https') {
        return _pinnedSecureConnect(uri, judged: judged);
      }
      return Socket.startConnect(judged, uri.port);
    };
    return client;
  }

  /// Resolve [host] through the app's one resolver and return the address an
  /// http page-steered connection pins to, or throw: [PageSteeredPrivateTarget]
  /// when any resolved address is in a private or loopback range (unless
  /// [allowPrivate]), a [SocketException] when the name does not resolve here.
  /// Refusing on *any* private address matches [classifyResolvedHost], so a
  /// name that answers with one public and one private address is refused, not
  /// raced.
  static Future<InternetAddress> _judgedAddress(String host,
      {required bool allowPrivate}) async {
    final addresses = await hostLookup(host);
    if (addresses == null || addresses.isEmpty) {
      throw SocketException('$host did not resolve');
    }
    if (!allowPrivate) {
      for (final a in addresses) {
        if (isPrivateOrLoopbackHost(a)) {
          throw PageSteeredPrivateTarget(Host(host), resolvedAddress: a);
        }
      }
    }
    return InternetAddress(addresses.first);
  }

  /// A TLS connection for an https URL a page can steer, pinned to the already
  /// [judged] address: the raw socket connects only to it, and TLS runs over
  /// that socket with SNI and certificate verification against the hostname
  /// ([uri.host]). The TLS session is bound to the name while the socket is
  /// pinned to the judged address, so a rebind cannot be probed by the handshake
  /// itself — no byte, not even the ClientHello, reaches an address the judge
  /// did not accept.
  static Future<ConnectionTask<Socket>> _pinnedSecureConnect(Uri uri,
      {required InternetAddress judged}) async {
    final Future<SecureSocket> secured = Socket.connect(judged, uri.port).then(
        (raw) => SecureSocket.secure(
              raw,
              host: uri.host,
              onBadCertificate: (cert) =>
                  _isTrustedBadCert(cert, host: uri.host, port: uri.port),
            ));
    return _cancellableConnect(secured);
  }

  /// [http.Client] routed through the HTTP proxy at [addr]. With [tls] the
  /// hop to the proxy is a TLS session: the factory hands dart:io a
  /// `SecureSocket` to the proxy, so `CONNECT` and the Basic credentials go
  /// out inside it, and dart:io nests the origin's own TLS through the
  /// tunnel as it would over a plain socket. The proxy's certificate is
  /// checked against system trust, or a fingerprint the user pinned.
  static OutboundClient _httpProxyClient(
    UserProxySettings settings, {
    required String addr,
    required (String, int) hostPort,
    required bool tls,
    required BodyEncoding encoding,
    bool pageSteered = false,
  }) {
    final inner = _newHttpClient(encoding: encoding);
    inner.findProxy = (uri) {
      // A page-steered client gets no localhost bypass: for a page a loopback
      // destination is the SSRF to block, and letting it go DIRECT would reopen
      // the rebind/redirect hole the pin closes (SEC-049). Everything it fetches
      // goes to the proxy, which resolves and connects at the far end.
      if (!pageSteered && _isLocalhost(uri.host.toLowerCase())) return 'DIRECT';
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
    if (tls) {
      inner.connectionFactory = (uri, proxyHost, proxyPort) {
        if (proxyHost == null || proxyPort == null) {
          return uri.scheme == 'https'
              ? SecureSocket.startConnect(
                  uri.host,
                  uri.port,
                  onBadCertificate: (cert) =>
                      _isTrustedBadCert(cert, host: uri.host, port: uri.port),
                )
              : Socket.startConnect(uri.host, uri.port);
        }
        return SecureSocket.startConnect(
          proxyHost,
          proxyPort,
          onBadCertificate: (cert) =>
              _isTrustedBadCert(cert, host: proxyHost, port: proxyPort),
        );
      };
    }
    return OutboundClientReady(IOClient(inner));
  }

  static bool _isTrustedBadCert(X509Certificate cert,
      {required String host, required int port}) {
    return TrustedHostsService.instance.isTrusted(
      host: host,
      port: port,
      fingerprint: fingerprintFromX509(cert),
    );
  }

  /// Builds an [http.Client] whose `connectionFactory` tunnels each request
  /// through the SOCKS5 server at [host]:[port]. The destination hostname is
  /// passed through to the SOCKS5 server (`InternetAddressType.unix`), so
  /// the local resolver never learns where the user is browsing.
  static OutboundClient _socks5Client({
    required String host,
    required int port,
    String? username,
    String? password,
    required BodyEncoding encoding,
  }) {
    final inner = _newHttpClient(encoding: encoding);
    final SocksProxy via =
        (host: host, port: port, username: username, password: password);
    inner.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (uri.scheme == 'https') {
        // The SOCKS5 path bypasses HttpClient's TLS handshake (the
        // session is made on the tunnel), so the trust list
        // has to be re-checked here too — otherwise self-signed sites
        // accessible only through a SOCKS5 tunnel (Tor onion services
        // talking to the user's self-hosted backend) get a hard
        // HandshakeException despite the user trusting the cert.
        return _cancellableConnect(socksConnectSecure(
          via: via,
          host: uri.host,
          port: uri.port,
          onBadCertificate: (cert) => TrustedHostsService.instance.isTrusted(
            host: uri.host,
            port: uri.port,
            fingerprint: fingerprintFromX509(cert),
          ),
        ));
      }
      return _cancellableConnect(
          socksConnect(via: via, host: uri.host, port: uri.port));
    };
    return OutboundClientReady(IOClient(inner));
  }
}

/// Build the page-steered client for [route] on [factory] — the sole producer
/// of a page-steered client, hidden from `outbound_http.dart`'s public
/// re-export so no caller outside the seam can name it (SEC-049). The real
/// connection pin and literal guard live on [DefaultOutboundHttpFactory]; any
/// other factory (a test fake) has no socket of its own, so its page-steered
/// client is its [OutboundHttpFactory.clientFor] — the connection-layer test
/// exercises the real pin, the fakes capture the fetch.
OutboundClient buildPageSteeredClient(
  OutboundHttpFactory factory, {
  required ProxyRoute route,
  String? allowPrivateHost,
}) {
  if (factory is DefaultOutboundHttpFactory) {
    return factory._pageSteeredBuild(route, allowPrivateHost: allowPrivateHost);
  }
  // A non-default factory has no pin of its own, so it fails closed unless it
  // opts in (a test fake that captures the fetch); production never reaches
  // here, since the only non-default factory is one a test installs.
  return factory is PageSteeredCapturingFactory
      ? factory.clientFor(route)
      : const OutboundClientBlocked(
          'a page-steered client needs the default outbound factory');
}

/// A direct client was asked to connect to an onion service: nothing was
/// sent, and the name never reached the device's resolver (LEAK-016). A
/// [SocketException], so every caller reads it as the failed connection it
/// is.
final class OnionNeedsProxyFailure extends SocketException {
  OnionNeedsProxyFailure(this.host)
      : super('$host is an onion service, reached only through Tor or a '
            'proxy');

  final Host host;
}

/// A page-steered client refused to connect: [host] resolves to [address],
/// which is in a private or loopback range a request a loaded page can steer
/// may not reach (SEC-049). Nothing was sent. A [SocketException], so every
/// caller reads it as the failed connection it is.
final class PageSteeredPrivateTarget extends SocketException {
  PageSteeredPrivateTarget(this.host, {required this.resolvedAddress})
      : super('$host resolves to $resolvedAddress, a private or loopback '
            'address a page-steered request may not reach');

  final Host host;
  final String resolvedAddress;
}

/// Refuses a page-steered request to a private or loopback *literal* on any
/// route (SEC-049): under a proxy a name travels to the proxy and is resolved
/// there, but `http://127.0.0.1/` or `http://[::1]/` must not become a way to
/// reach the loopback the direct pin guards. [allowPrivateHost] (lowercased) is
/// the one host whose own private literal is permitted. On a DEFAULT route the
/// direct client also resolves and judges; this is the literal half, the same
/// on every route, and the only range check the proxied fetchers without one of
/// their own (favicons, page icon bytes) get under a proxy.
class _PageSteeredLiteralGuard extends http.BaseClient {
  _PageSteeredLiteralGuard(this._inner,
      {this.allowPrivateHost, this.resolvesLocally = false});

  final http.Client _inner;
  final String? allowPrivateHost;

  /// Whether this wraps the DEFAULT direct client, where the destination is
  /// resolved on the device (so a per-request local check is meaningful), rather
  /// than a proxied client that resolves at the far end.
  final bool resolvesLocally;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;
    final allowed =
        allowPrivateHost != null && host.toLowerCase() == allowPrivateHost;
    if (!allowed && isPrivateOrLoopbackHost(host)) {
      throw PageSteeredPrivateTarget(Host(host), resolvedAddress: host);
    }
    // An onion host must never reach the device's resolver (LEAK-016): refuse it
    // before the per-request resolve below could look it up. On a DEFAULT route
    // the destination is resolved on the device, so this is where the leak would
    // be; a proxied route resolves at the far end and never calls this.
    if (resolvesLocally && Host(host).isOnion) {
      throw OnionNeedsProxyFailure(Host(host));
    }
    // A DEFAULT page-steered request carried by an OS env proxy: dart:io pools
    // plain-http connections by the proxy's host:port, so a second destination
    // reuses the first's connection and the per-connection connectionFactory
    // judge never runs for it (likewise a redirect hop over a kept-alive proxied
    // connection). Resolve and judge the destination here, per request, so a
    // pooled or reused connection cannot carry an unjudged private target (M1,
    // BUG-012). A non-DEFAULT route resolves at the far end; a DIRECT env (no
    // proxy) opens a judged connection per new host, so neither needs this.
    if (resolvesLocally && _pageSteeredFindProxy(request.url) != 'DIRECT') {
      await DefaultOutboundHttpFactory._judgedAddress(host,
          allowPrivate: allowed);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// How a page-steered DEFAULT request discovers an OS env proxy. The direct
/// client routes by it and the per-request guard reads it, so the two agree on
/// whether a proxy carries the request. Defaults to the process environment; a
/// test overrides it to simulate `http_proxy` without mutating the real
/// environment (M1, BUG-012).
String Function(Uri url) _pageSteeredFindProxy =
    HttpClient.findProxyFromEnvironment;

@visibleForTesting
set pageSteeredFindProxy(String Function(Uri url) f) =>
    _pageSteeredFindProxy = f;

@visibleForTesting
void resetPageSteeredFindProxy() =>
    _pageSteeredFindProxy = HttpClient.findProxyFromEnvironment;

/// A SOCKS5 connect cannot be aborted mid-handshake, so cancelling it only
/// marks it, and a socket that arrives after the cancel is destroyed on
/// arrival. Errors stay on the one future dart:io observes: an `onCancel` that
/// awaited the connect again gave a refused connect (Tor's `ttlExpired`) a
/// second, unobserved future to escape through.
ConnectionTask<S> _cancellableConnect<S extends Socket>(Future<S> connect) {
  var cancelled = false;
  final socket = connect.then((s) {
    if (cancelled) s.destroy();
    return s;
  });
  return ConnectionTask.fromSocket(socket, () => cancelled = true);
}

bool _isLocalhost(String host) {
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}
