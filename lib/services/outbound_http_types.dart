// Platform-neutral half of the outbound HTTP seam: the proxy resolution rule,
// the sealed client result, the factory contract and the DNT wrapper. Kept free
// of dart:io so screens that transitively reach this seam still compile for the
// web target (see tool/design_gallery/CLAUDE.md); the dart:io implementation
// lives in outbound_http_io.dart.

import 'package:http/http.dart' as http;

import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';

export 'package:webspace/services/tor_engine.dart'
    show TorRoute, TorRouteUp, TorRouteBlocked;

/// The proxy a connection goes through, with whose traffic it is decided
/// (BUG-030): a site's, its settings with its Tor isolation tag stamped in
/// ([OutboundProxy.ofSite]), or the app's ([OutboundProxy.app],
/// [OutboundProxy.ofApp]). A site's stored settings reach a connection, or
/// [resolved], only through one of them, so they never go untagged onto the
/// app-global circuit, where they could be linked to the site.
extension type OutboundProxy._(UserProxySettings settings) {
  /// [stored] as [site] sends it: for every type but [ProxyType.TOR] the
  /// settings themselves; for Tor a copy carrying [site] as the SOCKS5
  /// stream-isolation tag. A copy, so the user's manual username survives a
  /// trip through Tor and switching back restores it (PROXY-010).
  factory OutboundProxy.ofSite(
    UserProxySettings stored, {
    required SiteId site,
  }) => OutboundProxy._(
    stored.type == ProxyType.TOR
        ? UserProxySettings(
            type: ProxyType.TOR,
            address: stored.address,
            username: site,
            torExitCountry: stored.torExitCountry,
          )
        : stored,
  );

  /// Settings the app holds for itself rather than for a site: the global
  /// proxy, a proxy library entry under test. A Tor proxy keeps the tag its
  /// username carries, else takes the app-global one.
  factory OutboundProxy.ofApp(UserProxySettings settings) =>
      OutboundProxy._(settings);

  /// Traffic that belongs to no site (a preview before a site exists, a
  /// suggestion's icon, the global scripts): the app-wide outbound proxy,
  /// resolved at the call, with a Tor proxy on the app-global tag
  /// (PROXY-011).
  static OutboundProxy get app =>
      OutboundProxy._(UserProxySettings(type: ProxyType.DEFAULT));

  /// The route this traffic takes.
  ///
  /// DEFAULT falls through to the **global** outbound proxy
  /// ([GlobalOutboundProxy.current]): "I configured a global proxy (e.g.
  /// Tor); a site I haven't customized should also go through it." Any other
  /// type wins over the global.
  ///
  /// What a setting takes from the proxy library (a saved proxy, a saved
  /// gateway, saved credentials), on the site or on the global, is resolved
  /// here (PROXY-030). A reference that resolves to nothing comes back SAVED
  /// with no address and fails closed downstream; it never falls through to
  /// the global, which is a route the user did not pick for that site.
  ///
  /// Applied at every outbound seam, Dart-side HTTP *and* the native webview
  /// proxy, so a site set to DEFAULT doesn't silently bypass the global proxy
  /// in either direction. A Tor proxy rides the tag it carries: a site's own
  /// for one it set itself, so each site rides its own circuit, and the
  /// app-global tag for one inherited through DEFAULT, since inheriting the
  /// app's default proxy is not the same request as opting into per-site
  /// isolation, and conflating them would hand every uncustomized site a
  /// circuit of its own (PROXY-011).
  ProxyRoute get resolved {
    if (settings.type == ProxyType.DEFAULT) {
      final global = resolveLibraryProxy(GlobalOutboundProxy.current);
      return ProxyRoute._(global.type == ProxyType.TOR
          ? _torTagged(global, tag: TorTag.app)
          : global);
    }
    if (settings.type == ProxyType.TOR) {
      return ProxyRoute._(_torTagged(settings, tag: null));
    }
    return ProxyRoute._(resolveLibraryProxy(settings));
  }
}

/// Settings a connection can be opened on: DEFAULT fallen through to the
/// global proxy, what they take from the proxy library filled in, a Tor
/// proxy's isolation tag stamped. Only [OutboundProxy.resolved] makes one, so
/// [OutboundHttpFactory.clientFor] never opens a client on stored settings.
extension type ProxyRoute._(UserProxySettings settings)
    implements UserProxySettings {}

/// The route [siteId]'s traffic takes when its stored setting is [perSite]
/// ([OutboundProxy.resolved]).
ProxyRoute resolveEffectiveProxy(
  UserProxySettings perSite, {
  required SiteId siteId,
}) => OutboundProxy.ofSite(perSite, site: siteId).resolved;

/// Stamp the isolation tag into `username`, where the SOCKS5 expansion later
/// reads it. Carrying the tag on the settings object keeps `clientFor` a
/// one-argument function all the way down.
/// Precedence: an explicit [tag], else a tag the settings object already
/// carries ([OutboundProxy.ofSite] stamps a site's there), else app-global.
UserProxySettings _torTagged(UserProxySettings s, {required TorTag? tag}) {
  final existing = s.username;
  final stamped = tag ??
      ((existing != null && existing.isNotEmpty)
          ? TorTag.fromWire(existing)
          : TorTag.app);
  return UserProxySettings(
    type: ProxyType.TOR,
    address: s.address,
    username: stamped,
    password: null,
    // The pin rides the effective settings so a site left on DEFAULT that
    // inherits a global Tor inherits the global's country too, rather than
    // reading as unpinned and evicting every pinned neighbour (TOR-014).
    torExitCountry: s.torExitCountry,
  );
}

/// Split a `host:port` proxy address, or null if it is not one.
///
/// Splits on the LAST colon so a bracketed IPv6 literal (`[::1]:8080`)
/// keeps its host. Both per-site proxy mechanisms, the native per-WebView
/// binding and the Android router's route table, parse addresses through
/// here, so they cannot disagree on IPv6.
({String host, int port})? splitProxyAddress(String? address) =>
    switch (ProxyAddressParse.of(address)) {
      ProxyAddress(:final host, :final port) => (host: host, port: port),
      ProxyAddressMissing() ||
      ProxyAddressMalformed() ||
      ProxyAddressBadPort() => null,
    };

/// Expands a tagged [ProxyType.TOR] into live SOCKS5 settings, or says why
/// the runtime is not up.
typedef TorProxyResolver = TorRoute Function(TorTag tag);

/// Installed once at startup from `TorService`. Left null, every TOR request
/// blocks — which is the correct default: a missing resolver must never mean
/// "connect directly" (TOR-008).
TorProxyResolver? torProxyResolver;

/// Shared TOR expansion for both outbound seams (Dart HTTP and the native
/// webview). Anything but [TorRouteUp] means block.
TorRoute expandTorProxy(UserProxySettings settings) {
  assert(settings.type == ProxyType.TOR, 'only a TOR setting expands');
  final username = settings.username;
  final resolver = torProxyResolver;
  if (resolver == null) {
    return const TorRouteBlocked('Tor is not set up yet in this launch.');
  }
  return resolver(username == null || username.isEmpty
      ? TorTag.app
      : TorTag.fromWire(username));
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

/// Wrap [inner] so every request it sends for a site carries the user agent
/// the site's webview sends, when [userAgent] gives one: a site that walls
/// other clients answers these as it answers the site (linkedin.com sends a
/// CAPTCHA page in place of its 301 to www.linkedin.com). A header the
/// caller set wins.
class SiteUserAgentClient extends http.BaseClient {
  SiteUserAgentClient(this._inner, {required this.userAgent});

  final http.Client _inner;
  final Future<String?> Function() userAgent;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final agent = await userAgent();
    if (agent != null) request.headers.putIfAbsent('User-Agent', () => agent);
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

/// A SOCKS5 proxy answered and refused the handshake: a credential it would
/// not take, a protocol it does not speak, or a CONNECT it could not make.
/// [message] is the refusal as the SOCKS client reported it.
final class SocksHandshakeFailure implements IOException {
  const SocksHandshakeFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Contract for producing an [http.Client] that routes through a given
/// [ProxyRoute]. This is the seam that lets every Dart-side outbound call
/// honor a per-site or app-global proxy.
///
/// Tests replace [outboundHttp] with a fake to assert what proxy each call
/// site requested without performing real I/O.
abstract class OutboundHttpFactory {
  OutboundClient clientFor(
    ProxyRoute route, {
    BodyEncoding encoding = BodyEncoding.decoded,
  });
}

/// What a client does with a body the server compressed.
enum BodyEncoding {
  /// Decoded as it arrives, as a fetch wants it.
  decoded,

  /// As the server sent it, so the Content-Length still counts the bytes
  /// that arrive and the caller decodes them: a download, whose progress
  /// is the wire bytes against that length. A browser decodes regardless.
  asSent,
}

/// Parse `host:port`. Returns null on invalid input. Used by the dart:io
/// factory as well as tests, so it cannot be test-only.
(String, int)? parseHostPort(String addr) => switch (splitProxyAddress(addr)) {
  (:final host, :final port) => (host, port),
  null => null,
};

/// TOR-008: whether a site's webview must wait for the Tor runtime. Resolves
/// DEFAULT through the global proxy (PROXY-011), so a site that inherits a
/// global Tor is gated exactly like one that opted into Tor itself.
bool waitsForTor(OutboundProxy proxy, {required bool torUp}) =>
    !torUp && proxy.resolved.type == ProxyType.TOR;
