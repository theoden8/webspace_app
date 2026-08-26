// dart:io half of the outbound HTTP seam. Unchanged from when this was one
// file: the native proxy, SOCKS5 and certificate-pinning behaviour must not
// vary because the web target exists.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart' as socks5;

import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/trusted_hosts_x509.dart';
import 'package:webspace/settings/proxy.dart';

/// Default factory backed by `dart:io`'s [HttpClient].
///
/// - DEFAULT  → direct client (system proxy, if any, is honored by dart:io)
/// - HTTP/HTTPS → [HttpClient.findProxy] override pointing at the host:port
/// - SOCKS5  → connection factory tunnels every request via the
///            [socks5_proxy] package; the SOCKS5 server resolves the
///            destination hostname, so the user's local resolver never
///            sees it (matches Tor's `dns_proxy` semantics).
class DefaultOutboundHttpFactory implements OutboundHttpFactory {
  const DefaultOutboundHttpFactory();

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    switch (settings.type) {
      case ProxyType.DEFAULT:
        return OutboundClientReady(IOClient(_newHttpClient()));

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
        return OutboundClientReady(IOClient(inner));

      case ProxyType.TOR:
        // TOR carries no address of its own; it expands at use-time into
        // the loopback SOCKS5 endpoint plus this caller's isolation tag.
        // A null expansion means the runtime is not up, and the only safe
        // answer is to block: falling through to SOCKS5-with-no-address or
        // to a direct client would put the request on the device IP, which
        // is the exact thing the user turned Tor on to prevent (TOR-008).
        final tor = expandTorProxy(settings);
        if (tor == null) {
          return const OutboundClientBlocked(
            'Tor is not bootstrapped yet. Outbound request blocked to avoid '
            'leaking the device IP via a direct fallback.',
          );
        }
        return clientFor(tor);

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
    client.badCertificateCallback = _isTrustedBadCert;
    return client;
  }

  static bool _isTrustedBadCert(X509Certificate cert, String host, int port) {
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
    inner.connectionFactory = (uri, proxyHost, proxyPort) async {
      final InternetAddress proxyAddr;
      if (_isIpLiteral(host)) {
        proxyAddr = InternetAddress(host);
      } else {
        // Hostname: do a one-time lookup. The SOCKS5 server itself is
        // reached via plain DNS — only the user's *destination* hostnames
        // are tunneled through SOCKS5. For the typical Tor setup
        // (`127.0.0.1:9050`) this branch is never taken.
        final addrs = await InternetAddress.lookup(host);
        if (addrs.isEmpty) {
          throw const SocketException('SOCKS5 proxy host did not resolve');
        }
        proxyAddr = addrs.first;
      }
      final proxies = [
        socks5.ProxySettings(proxyAddr, port,
            username: username, password: password),
      ];
      final socket = socks5.SocksTCPClient.connect(
        proxies,
        InternetAddress(uri.host, type: InternetAddressType.unix),
        uri.port,
      );
      if (uri.scheme == 'https') {
        // The SOCKS5 path bypasses HttpClient's TLS handshake (the
        // secure() call below is on the raw socket), so the trust list
        // has to be re-checked here too — otherwise self-signed sites
        // accessible only through a SOCKS5 tunnel (Tor onion services
        // talking to the user's self-hosted backend) get a hard
        // HandshakeException despite the user trusting the cert.
        final secure = (await socket).secure(
          uri.host,
          onBadCertificate: (cert) => TrustedHostsService.instance.isTrusted(
            host: uri.host,
            port: uri.port,
            fingerprint: fingerprintFromX509(cert),
          ),
        );
        return ConnectionTask.fromSocket(
          secure,
          () async => (await secure).close().ignore(),
        );
      }
      return ConnectionTask.fromSocket(
        socket,
        () async => (await socket).close().ignore(),
      );
    };
    return OutboundClientReady(IOClient(inner));
  }
}

/// Whether [host] looks like an IPv4 / IPv6 literal — i.e. safe to pass
/// directly to [InternetAddress] without a DNS lookup.
bool _isIpLiteral(String host) {
  try {
    InternetAddress(host);
    return true;
  } catch (_) {
    return false;
  }
}

bool _isLocalhost(String host) {
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}
