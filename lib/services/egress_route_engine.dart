import 'package:webspace/settings/network_interface.dart';
import 'package:webspace/settings/proxy.dart';

/// The egress relay as the running app has it (network-interface NETIF-004).
sealed class EgressRelayState {
  const EgressRelayState();
}

/// The experiment is not reachable here or now: a stored interface is kept
/// and not applied (NETIF-013).
final class EgressOff extends EgressRelayState {
  const EgressOff();
}

/// The experiment is on and no relay runs: a bound site has no route
/// (NETIF-002).
final class EgressDown extends EgressRelayState {
  const EgressDown();
}

/// The relay listens at [host]:[port] and serves whoever presents [secret].
final class EgressUp extends EgressRelayState {
  const EgressUp({
    required this.host,
    required this.port,
    required this.secret,
  });

  final String host;
  final int port;

  /// Minted per run and never persisted, like the router's tokens
  /// (PROXY-023).
  final String secret;
}

/// How the relay carries a route of each proxy type over an interface
/// (NETIF-005): it dials the origin, or a SOCKS5 or HTTP proxy, itself; a
/// proxy with its own first hop on the device (Tor, NETIF-006), one whose TLS
/// the relay does not run yet (HTTPS), or a library entry that resolved to
/// nothing has no route through an interface.
enum UpstreamCarriage {
  direct(wire: null),
  socks5(wire: 'socks5'),
  http(wire: 'http'),
  tor(wire: null),
  tlsProxy(wire: null),
  unresolved(wire: null);

  const UpstreamCarriage({required this.wire});

  /// The relay's name for the upstream's protocol.
  final String? wire;

  static UpstreamCarriage of(ProxyType type) => switch (type) {
    ProxyType.DEFAULT => direct,
    ProxyType.SOCKS5 => socks5,
    ProxyType.HTTP => http,
    ProxyType.TOR => tor,
    ProxyType.HTTPS => tlsProxy,
    ProxyType.SAVED || ProxyType.GATEWAY => unresolved,
  };
}

/// Whether a site's interface is applied now: it names one, and the
/// experiment is reachable. A site that is counts as routed wherever a
/// proxied one does (NETIF-008).
bool appliesInterface(
  InterfaceChoice leavesBy, {
  required EgressRelayState relay,
}) => leavesBy is! SystemRouting && relay is! EgressOff;

/// What a site's traffic takes when its settings name [leavesBy] and its
/// proxy resolves to [route]: [route] itself while the interface is not
/// applied, SOCKS5 to the relay with the whole route in its credential, or
/// a route that goes nowhere ([ProxyType.SAVED] with no address, which every
/// seam already refuses).
UserProxySettings egressRoute({
  required UserProxySettings route,
  required InterfaceChoice leavesBy,
  required EgressRelayState relay,
}) {
  if (!appliesInterface(leavesBy, relay: relay)) return route;
  final link = switch (leavesBy) {
    NamedInterface(:final name) => name,
    SystemRouting() || UnreadableInterface() => null,
  };
  final up = switch (relay) {
    final EgressUp up => up,
    EgressOff() || EgressDown() => null,
  };
  if (link == null || up == null) return _nowhere;
  final carriage = UpstreamCarriage.of(route.type);
  final credential = switch (carriage) {
    UpstreamCarriage.direct => _credential(
      link: link,
      upstream: null,
      secret: up.secret,
    ),
    UpstreamCarriage.socks5 || UpstreamCarriage.http => _credential(
      link: link,
      upstream: (route: route, wire: carriage.wire!),
      secret: up.secret,
    ),
    UpstreamCarriage.tor ||
    UpstreamCarriage.tlsProxy ||
    UpstreamCarriage.unresolved => null,
  };
  if (credential == null) return _nowhere;
  return UserProxySettings(
    type: ProxyType.SOCKS5,
    address: '${up.host}:${up.port}',
    username: credential.username,
    password: credential.password,
  );
}

UserProxySettings get _nowhere => UserProxySettings(type: ProxyType.SAVED);

/// The SOCKS5 credential `linux/egress_relay_core.h` reads, or null when it
/// does not fit: RFC 1929 carries 255 bytes of each.
({String username, String password})? _credential({
  required InterfaceName link,
  required ({UserProxySettings route, String wire})? upstream,
  required String secret,
}) {
  String e(String value) => Uri.encodeComponent(value);
  final buffer = StringBuffer('ws-egress-1?if=${e(link)}');
  String? upstreamPassword;
  if (upstream case (:final route, :final wire)) {
    if (ProxyAddressParse.of(route.address) case ProxyAddress(
      :final host,
      :final port,
    )) {
      buffer.write('&t=$wire&h=${e(host)}&p=$port');
    } else {
      return null;
    }
    final user = route.username;
    if (user != null && user.isNotEmpty) buffer.write('&u=${e(user)}');
    upstreamPassword = route.password;
  }
  final username = buffer.toString();
  final password = upstreamPassword == null || upstreamPassword.isEmpty
      ? secret
      : '$secret.${e(upstreamPassword)}';
  if (username.length > 255 || password.length > 255) return null;
  return (username: username, password: password);
}
