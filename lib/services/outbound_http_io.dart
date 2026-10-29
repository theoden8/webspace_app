// dart:io half of the outbound HTTP seam. The native proxy, SOCKS5 and
// certificate-pinning behaviour must not vary because the web target exists.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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
  OutboundClient clientFor(ProxyRoute route) => _clientFor(route);

  OutboundClient _clientFor(UserProxySettings settings) {
    switch (settings.type) {
      case ProxyType.DEFAULT:
        return OutboundClientReady(IOClient(_directHttpClient()));

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
        );

      case ProxyType.TOR:
        // TOR carries no address of its own; it expands at use-time into
        // the loopback SOCKS5 endpoint plus this caller's isolation tag.
        // While the runtime is not up the only safe answer is to block:
        // falling through to SOCKS5-with-no-address or to a direct client
        // would put the request on the device IP, which is the exact thing
        // the user turned Tor on to prevent (TOR-008).
        return switch (expandTorProxy(settings)) {
          TorRouteUp(:final socks) => _clientFor(socks),
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
  static HttpClient _newHttpClient() {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) =>
        _isTrustedBadCert(cert, host: host, port: port);
    return client;
  }

  /// A client no proxy carries. It refuses an onion service before anything
  /// resolves it: only Tor does, so a direct connection would only hand the
  /// name to the device's resolver (LEAK-016). Asked per connection, so a
  /// redirect to one is refused too. Otherwise it connects as dart:io would
  /// without a factory.
  static HttpClient _directHttpClient() {
    final client = _newHttpClient();
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
  }) {
    final inner = _newHttpClient();
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
  }) {
    final inner = _newHttpClient();
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
