// The one SOCKS5 dial in the app, over the socks5_proxy package. dart:io
// only, like outbound_http_io.dart; what a caller names when it fails,
// [SocksHandshakeFailure], lives in outbound_http_types.dart.

import 'dart:io';

import 'package:socks5_proxy/exceptions.dart' as socks5;
import 'package:socks5_proxy/socks_client.dart' as socks5;

import 'package:webspace/services/outbound_http_types.dart'
    show SocksHandshakeFailure;

/// A SOCKS5 proxy as the dial reaches it.
typedef SocksProxy = ({
  String host,
  int port,
  String? username,
  String? password,
});

/// A socket to [host]:[port] through [via]. The destination name goes to
/// the proxy unresolved (`InternetAddressType.unix`), so the local resolver
/// never learns where the user is browsing; only the proxy's own host is
/// looked up here.
///
/// Fails with [SocketException] when the proxy cannot be reached, and with
/// [SocksHandshakeFailure] when it answers and refuses.
Future<Socket> socksConnect({
  required SocksProxy via,
  required String host,
  required int port,
}) async =>
    _typed(socks5.SocksTCPClient.connect(
        await _proxies(via), _destination(host), port));

/// [socksConnect], then a TLS session to [host] inside the tunnel, the
/// handshake an HttpClient makes itself on a socket it opened.
/// [onBadCertificate] judges a certificate the platform does not trust; a
/// TLS handshake that fails throws its [TlsException].
Future<SecureSocket> socksConnectSecure({
  required SocksProxy via,
  required String host,
  required int port,
  required bool Function(X509Certificate certificate) onBadCertificate,
}) async {
  final tunnel = await _typed(socks5.SocksTCPClient.connect(
      await _proxies(via), _destination(host), port));
  return tunnel.secure(host, onBadCertificate: onBadCertificate);
}

/// [handshake], the library's dial, failing only as [socksConnect] says.
/// Generic so the socket keeps the library's own type, whose `secure` a TLS
/// dial needs and which the library does not export.
Future<T> _typed<T>(Future<T> handshake) async {
  try {
    return await handshake;
  } on SocketException {
    rethrow;
  } on socks5.SocksClientException catch (e) {
    throw SocksHandshakeFailure('$e');
  } on FormatException catch (e) {
    throw SocksHandshakeFailure('$e');
  } on RangeError catch (e) {
    // A reply code past the ones it knows indexes past its enum
    // (socks_client.dart:209): tor's ExtendedErrors replies 0xF0-0xF7.
    throw SocksHandshakeFailure('$e');
  } on TypeError catch (e) {
    // An address type it does not know fails its `!` (socks_client.dart:219).
    throw SocksHandshakeFailure('$e');
    // ignore: webspace_lints/catch_all
  } on Exception catch (e) {
    // socks5_proxy 2.1.1 refuses a handshake with a plain Exception
    // (lib/src/client/socks_client.dart:139-208), which no narrower type names.
    throw SocksHandshakeFailure('$e');
  }
}

Future<List<socks5.ProxySettings>> _proxies(SocksProxy via) async => [
      socks5.ProxySettings(await _proxyAddress(via.host), via.port,
          username: via.username, password: via.password),
    ];

/// [host] as the library sends a name unresolved.
InternetAddress _destination(String host) =>
    InternetAddress(host, type: InternetAddressType.unix);

/// The proxy's address: [host] itself when it is a literal, else its first
/// DNS answer. The proxy is reached through the device's resolver; only the
/// destination is resolved at the far end.
Future<InternetAddress> _proxyAddress(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return literal;
  final found = await InternetAddress.lookup(host);
  if (found.isEmpty) {
    throw const SocketException('The SOCKS5 proxy host did not resolve');
  }
  return found.first;
}
