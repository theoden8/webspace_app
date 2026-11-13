// Host-range classification for outbound URLs that page JS can steer.
//
// Two halves, and the difference between them is the point:
//
//   * [isPrivateOrLoopbackHost] judges the *literal* in the URL. Pure, sync,
//     and correct for `http://127.0.0.1/`, `http://[::1]/`,
//     `http://169.254.169.254/`.
//   * [hostLookup] resolves a name so the caller can judge what it actually
//     points at. `http://evil.example/` whose A record is `127.0.0.1` passes
//     every literal check ever written; only a resolution catches it.
//
// The lookup comes from host_platform because `InternetAddress.lookup` is
// dart:io, and this file sits under widgets/screens' import closure
// (DESIGN-001). The web half reports "cannot resolve" rather than lying.

import 'package:meta/meta.dart';

import 'package:webspace/services/url_host.dart';
import 'package:webspace/settings/proxy.dart';

import 'package:webspace/platform/host_platform.dart'
    show IOException, hostLookupAddresses;

/// Resolves [host] to its addresses, or null when this build has no resolver.
/// Throws an [IOException] when the name does not resolve.
typedef HostLookup = Future<List<String>?> Function(String host);

HostLookup _lookup = hostLookupAddresses;

/// The installed resolver. Swap in tests; DNS in a unit test would be a
/// network dependency and an unpredictable answer.
HostLookup get hostLookup => _lookup;

@visibleForTesting
set hostLookup(HostLookup f) => _lookup = f;

@visibleForTesting
void resetHostLookup() => _lookup = hostLookupAddresses;

/// Whether [host] is a literal address in a range an outbound call driven by
/// page JS must never reach: loopback, RFC1918 private, unique-local,
/// link-local (which covers cloud metadata at 169.254.169.254), or the
/// `localhost` name.
///
/// Literals only. A hostname that *resolves* into one of these ranges walks
/// straight through — pair it with [hostLookup] where the caller is about to
/// connect through the device's own resolver.
bool isPrivateOrLoopbackHost(String raw) {
  final host = Host(raw);
  if (host.isLoopback) return true;

  if (host.contains(':')) {
    final List<int> bytes;
    try {
      bytes = Uri.parseIPv6Address(host.split('%').first); // drop any zone id
    } on FormatException {
      // A literal the parser cannot read is judged non-public, not waved
      // through: a resolver might still make an address of it (SEC-048).
      return true;
    }
    return _classifyIpBytes(bytes);
  }

  final octets = host.ipv4Octets;
  if (octets != null) return _classifyIpBytes(octets);
  // A numeric IPv4 in a non-canonical spelling (one decimal/hex number, hex or
  // octal octets, or fewer than four parts) that a resolver would still accept
  // as an address. Which address depends on the platform's inet_aton, so refuse
  // it here rather than guess the range wrong (SEC-048).
  if (_looksNumericIpv4(host)) return true;
  return false;
}

final RegExp _numericIpv4Part = RegExp(r'^(0x[0-9a-f]+|[0-9]+)$');

/// Whether [host] (lowercased, no port) is an IPv4 address written numerically
/// in an `inet_aton` spelling other than the canonical dotted-quad: one to four
/// dot-separated parts, each decimal, hex (`0x…`) or octal (leading zero).
/// [Host.ipv4Octets] accepts the canonical form first, so this catches the
/// rest.
bool _looksNumericIpv4(String host) {
  final parts = host.split('.');
  if (parts.isEmpty || parts.length > 4) return false;
  for (final p in parts) {
    if (!_numericIpv4Part.hasMatch(p)) return false;
  }
  return true;
}

bool _ipv4PrivateOrLoopback(List<int> o) {
  final a = o[0], b = o[1], c = o[2];
  if (a == 0) return true; // 0.0.0.0/8
  if (a == 127) return true; // loopback
  if (a == 10) return true; // private
  if (a == 172 && b >= 16 && b <= 31) return true; // private
  if (a == 192 && b == 168) return true; // private
  if (a == 169 && b == 254) return true; // link-local + cloud metadata
  if (a == 192 && b == 0 && c == 2) return true; // 192.0.2.0/24 documentation
  if (a == 198 && b == 51 && c == 100) return true; // 198.51.100.0/24 doc
  if (a == 203 && b == 0 && c == 113) return true; // 203.0.113.0/24 doc
  return false;
}

bool _embeddedV4PrivateOrLoopback({required int hi, required int lo}) =>
    _ipv4PrivateOrLoopback(<int>[hi >> 8, hi & 0xff, lo >> 8, lo & 0xff]);

/// Judge one address by its raw bytes, the same whether it was a literal in a
/// URL or an address a resolver returned (SEC-048 parity): four bytes for an
/// IPv4 address, sixteen for an IPv6 one folded back into its eight 16-bit
/// groups. The callers each produce one length or the other.
bool _classifyIpBytes(List<int> b) {
  if (b.length == 4) return _ipv4PrivateOrLoopback(b);
  final groups = <int>[
    for (var i = 0; i < b.length; i += 2) b[i] << 8 | b[i + 1],
  ];
  return _ipv6PrivateOrLoopback(groups);
}

bool _ipv6PrivateOrLoopback(List<int> g) {
  final lead5Zero =
      g[0] == 0 && g[1] == 0 && g[2] == 0 && g[3] == 0 && g[4] == 0;
  // IPv4-mapped (::ffff:v4): judge the embedded IPv4, so [::ffff:127.0.0.1] is
  // loopback and [::ffff:169.254.169.254] is link-local metadata (SEC-048).
  if (lead5Zero && g[5] == 0xffff) {
    return _embeddedV4PrivateOrLoopback(hi: g[6], lo: g[7]);
  }
  // `::` (unspecified) and `::1` (loopback), in any spelling.
  if (lead5Zero && g[5] == 0 && g[6] == 0 && (g[7] == 0 || g[7] == 1)) {
    return true;
  }
  // Deprecated IPv4-compatible (::v4): judge the embedded IPv4.
  if (lead5Zero && g[5] == 0 && (g[6] != 0 || g[7] > 1)) {
    return _embeddedV4PrivateOrLoopback(hi: g[6], lo: g[7]);
  }
  // NAT64 well-known 64:ff9b::/96 and local-use 64:ff9b:1::/48: embedded v4.
  if (g[0] == 0x0064 &&
      g[1] == 0xff9b &&
      ((g[2] == 0 && g[3] == 0 && g[4] == 0 && g[5] == 0) || g[2] == 0x0001)) {
    return _embeddedV4PrivateOrLoopback(hi: g[6], lo: g[7]);
  }
  // 6to4 2002:V4::/16: the embedded v4 gateway is groups 1-2.
  if (g[0] == 0x2002) return _embeddedV4PrivateOrLoopback(hi: g[1], lo: g[2]);
  // Teredo 2001:0000::/32 hides an obfuscated client v4; refuse, don't decode.
  if (g[0] == 0x2001 && g[1] == 0x0000) return true;
  // IPv6 documentation 2001:db8::/32: non-public.
  if (g[0] == 0x2001 && g[1] == 0x0db8) return true;
  if ((g[0] & 0xfe00) == 0xfc00) return true; // fc00::/7 unique-local
  if ((g[0] & 0xffc0) == 0xfe80) return true; // fe80::/10 link-local
  if ((g[0] & 0xffc0) == 0xfec0) return true; // fec0::/10 site-local (deprecated)
  if ((g[0] & 0xff00) == 0xff00) return true; // ff00::/8 multicast
  return false;
}

/// What [host] turned out to name.
enum HostRangeVerdict {
  /// Every address it resolves to is routable.
  public,

  /// At least one address is in a range [isPrivateOrLoopbackHost] rejects.
  private,

  /// The name did not resolve. A caller about to connect through the same
  /// resolver should refuse: the connection would fail anyway.
  unresolvable,

  /// Nothing here resolved it — this build has no resolver (web), or the
  /// destination is resolved at the far end of a proxy. Says nothing about
  /// the host; a caller must not read it as either verdict.
  notResolvedHere,
}

/// Resolve [host] and judge the addresses behind it.
///
/// Only meaningful when the caller is about to connect through *this device's*
/// resolver. Under a SOCKS5 or Tor proxy the destination name is resolved at
/// the far end, so a local answer describes a different network than the one
/// the request will traverse.
Future<HostRangeVerdict> classifyResolvedHost(String host) async {
  // Only Tor resolves an onion name; asked of this resolver it would answer
  // nothing and keep the name (LEAK-016).
  if (Host(host).isOnion) return HostRangeVerdict.unresolvable;
  final List<String>? addresses;
  try {
    addresses = await _lookup(host);
  } on IOException {
    return HostRangeVerdict.unresolvable;
  }
  if (addresses == null) return HostRangeVerdict.notResolvedHere;
  if (addresses.isEmpty) return HostRangeVerdict.unresolvable;
  for (final a in addresses) {
    if (isPrivateOrLoopbackHost(a)) {
      return HostRangeVerdict.private;
    }
  }
  return HostRangeVerdict.public;
}

/// Judge [url] for an outbound call whose destination page script can choose,
/// given the [effective] proxy that will carry it.
///
/// Returns [HostRangeVerdict.notResolvedHere] — say nothing, allow — under any
/// proxy. SOCKS5 and Tor resolve the destination at the far end by design (the
/// local resolver never sees the name), and an HTTP proxy is handed the name in
/// the request line. In all three, the addresses this device would resolve
/// describe a network the request never traverses, and a Tor user may have no
/// local resolver to consult in the first place.
///
/// Residual: an answer can change between this lookup and the client's own.
/// Closing that needs the connection pinned to the address checked, which the
/// `http` client does not expose.
Future<HostRangeVerdict> classifyOutboundTarget(
  String url, {
  required UserProxySettings effective,
}) async {
  if (effective.type != ProxyType.DEFAULT) return HostRangeVerdict.notResolvedHere;
  final host = Host.inUrl(url);
  if (host == null) return HostRangeVerdict.unresolvable;
  return classifyResolvedHost(host);
}
