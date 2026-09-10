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
// The lookup rides a conditional import because `InternetAddress.lookup` is
// dart:io, and this file sits under widgets/screens' import closure
// (DESIGN-001). The web half reports "cannot resolve" rather than lying.

import 'package:flutter/foundation.dart';

import 'package:webspace/settings/proxy.dart';

import 'package:webspace/services/host_resolution_web.dart'
    if (dart.library.io) 'package:webspace/services/host_resolution_io.dart';

/// Resolves [host] to its addresses, or null when this build has no resolver.
/// Throws when the name does not resolve.
typedef HostLookup = Future<List<String>?> Function(String host);

HostLookup _lookup = lookupHostAddresses;

/// The installed resolver. Swap in tests; DNS in a unit test would be a
/// network dependency and an unpredictable answer.
HostLookup get hostLookup => _lookup;

@visibleForTesting
set hostLookup(HostLookup f) => _lookup = f;

@visibleForTesting
void resetHostLookup() => _lookup = lookupHostAddresses;

/// Whether [host] is a literal address in a range an outbound call driven by
/// page JS must never reach: loopback, RFC1918 private, unique-local,
/// link-local (which covers cloud metadata at 169.254.169.254), or the
/// `localhost` name.
///
/// Literals only. A hostname that *resolves* into one of these ranges walks
/// straight through — pair it with [hostLookup] where the caller is about to
/// connect through the device's own resolver.
bool isPrivateOrLoopbackHost(String host) {
  if (host == 'localhost' || host.endsWith('.localhost')) return true;

  // IPv6 literal (Uri.host strips the surrounding brackets).
  if (host.contains(':')) {
    final h = host.split('%').first; // drop any zone id
    if (h == '::1' || h == '::') return true;
    // fc00::/7 unique-local, fe80::/10 link-local.
    if (h.startsWith('fc') || h.startsWith('fd')) return true;
    if (h.startsWith('fe8') ||
        h.startsWith('fe9') ||
        h.startsWith('fea') ||
        h.startsWith('feb')) {
      return true;
    }
    return false;
  }

  // IPv4 dotted-quad.
  final parts = host.split('.');
  if (parts.length == 4) {
    final octets = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return false; // not an IPv4 literal
      octets.add(v);
    }
    final a = octets[0], b = octets[1];
    if (a == 0) return true; // 0.0.0.0/8
    if (a == 127) return true; // loopback
    if (a == 10) return true; // private
    if (a == 172 && b >= 16 && b <= 31) return true; // private
    if (a == 192 && b == 168) return true; // private
    if (a == 169 && b == 254) return true; // link-local + cloud metadata
  }
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
  final List<String>? addresses;
  try {
    addresses = await _lookup(host);
  } catch (_) {
    return HostRangeVerdict.unresolvable;
  }
  if (addresses == null) return HostRangeVerdict.notResolvedHere;
  if (addresses.isEmpty) return HostRangeVerdict.unresolvable;
  for (final a in addresses) {
    if (isPrivateOrLoopbackHost(a.toLowerCase())) {
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
  String url,
  UserProxySettings effective,
) async {
  if (effective.type != ProxyType.DEFAULT) return HostRangeVerdict.notResolvedHere;
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) return HostRangeVerdict.unresolvable;
  return classifyResolvedHost(host);
}
