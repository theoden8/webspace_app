/// Proxy transports a site (or the app) can be pointed at.
///
/// [TOR] is resolved late: it carries no address of its own and
/// materializes at use-time into SOCKS5 against the loopback endpoint
/// [TorService] is listening on, with per-caller stream-isolation auth.
/// See `openspec/specs/tor-proxy/spec.md` (TOR-001/TOR-003).
///
/// [SAVED] and [GATEWAY] are resolved late too, from the proxy library
/// (PROXY-030): [SAVED] names a saved proxy by
/// [UserProxySettings.savedProxyId], [GATEWAY] a saved gateway by
/// [UserProxySettings.gatewayId]. Editing the entry moves every setting that
/// names it. One that no longer resolves carries no address, which every
/// seam already treats as unroutable.
///
/// Append new values only. The index is the serialized form, so
/// renumbering silently rewrites every user's stored proxy.
enum ProxyType { DEFAULT, HTTP, HTTPS, SOCKS5, TOR, SAVED, GATEWAY }

/// A route's identity: settings with equal keys put traffic on one route.
typedef ProxyRouteKey = ({
  ProxyType type,
  String? address,
  String? username,
  String? password,
});

class UserProxySettings {
  ProxyType type;
  String? address;
  String? username;
  String? password;

  /// ISO 3166-1 alpha-2 country the site's Tor traffic must exit from, or
  /// null for no constraint. Meaningful only under [ProxyType.TOR].
  ///
  /// Lives here rather than on `WebViewModel` so it rides the same
  /// `proxySettings` object every outbound seam already receives — a
  /// separate per-site field would need its own copy of the nested-webview
  /// propagation chain, and a pin that reaches the nested view while the
  /// proxy does not is the silent mis-routing that rule guards against.
  ///
  /// The pin is strict (`StrictNodes 1`): no usable exit means the request
  /// fails, never that it leaves from elsewhere. Because `ExitNodes` is a
  /// global tor option, two loaded sites pinned to different countries
  /// cannot coexist — see TOR-014.
  String? torExitCountry;

  /// The saved proxy this setting names. Meaningful only under
  /// [ProxyType.SAVED]; kept across a switch to another type for the same
  /// reason the manual fields are (PROXY-010).
  String? savedProxyId;

  /// The saved gateway this setting connects to. Meaningful only under
  /// [ProxyType.GATEWAY].
  String? gatewayId;

  /// Saved credentials to sign in with instead of [username] and
  /// [password]. Only a saved gateway the credentials list can take them;
  /// any other pairing fails closed.
  String? credentialsId;

  UserProxySettings({
    required this.type,
    this.address,
    this.username,
    this.password,
    this.torExitCountry,
    this.savedProxyId,
    this.gatewayId,
    this.credentialsId,
  });

  /// Which route these settings name, for telling two apart (PROXY-008).
  ///
  /// DEFAULT is "no proxy" whatever stale fields it kept from an earlier
  /// type. Anything else is its whole tuple, credentials included: the
  /// platform tells routes apart by them, Tor sites differ by the isolation
  /// tag in [username], and fixing a rejected password is a new route.
  /// Compare effective settings (`resolveEffectiveProxy`): until resolved, a
  /// DEFAULT or a library reference does not say where traffic goes.
  ProxyRouteKey get routeKey => type == ProxyType.DEFAULT
      ? (type: type, address: null, username: null, password: null)
      : (type: type, address: address, username: username, password: password);

  /// The pin as tor's `ExitNodes` value, or null when unpinned or invalid.
  ///
  /// Anything that is not two ASCII letters is dropped rather than passed
  /// through: a malformed value reaching `SETCONF` would be rejected by the
  /// control port and leave the previous country applied, which is worse
  /// than no pin because the user would believe a pin is in force.
  String? get exitNodesValue {
    final cc = torExitCountry?.trim().toLowerCase();
    if (cc == null || cc.length != 2) return null;
    if (!RegExp(r'^[a-z]{2}$').hasMatch(cc)) return null;
    return '{$cc}';
  }

  /// The password is intentionally never written to JSON. The canonical
  /// store for it is `flutter_secure_storage` via
  /// [ProxyPasswordSecureStorage]; both at-rest persistence
  /// (SharedPreferences) and the user-controlled backup export format
  /// strip it. After a backup restore the user re-enters proxy passwords
  /// — same UX contract as secure cookies, which are also export-stripped.
  /// See `openspec/specs/proxy-password-secure-storage/spec.md` (PWD-005).
  Map<String, dynamic> toJson() => {
        'type': type.index,
        'address': address,
        'username': username,
        if (torExitCountry != null) 'torExitCountry': torExitCountry,
        if (savedProxyId != null) 'savedProxyId': savedProxyId,
        if (gatewayId != null) 'gatewayId': gatewayId,
        if (credentialsId != null) 'credentialsId': credentialsId,
      };

  factory UserProxySettings.fromJson(Map<String, dynamic> json) {
    String? text(String key) {
      final value = json[key];
      return value is String ? value : null;
    }

    return UserProxySettings(
      type: _typeFromIndex(json['type']),
      address: text('address'),
      username: text('username'),
      password: text('password'),
      torExitCountry: text('torExitCountry'),
      savedProxyId: text('savedProxyId'),
      gatewayId: text('gatewayId'),
      credentialsId: text('credentialsId'),
    );
  }

  /// Decode a persisted [ProxyType] index defensively.
  ///
  /// A backup written by a newer build can carry an index this build has
  /// no value for (someone exports with TOR set, then rolls back). Reading
  /// it positionally would throw and take the whole settings load down, so
  /// an unknown index degrades to [ProxyType.DEFAULT] instead.
  static ProxyType _typeFromIndex(Object? raw) {
    final i = raw is int ? raw : int.tryParse('$raw');
    if (i == null || i < 0 || i >= ProxyType.values.length) {
      return ProxyType.DEFAULT;
    }
    return ProxyType.values[i];
  }

  /// PII-safe one-line summary suitable for [LogService] output that the
  /// user may share publicly when debugging proxy issues. Type and address
  /// are emitted verbatim (the address is `host:port`, not a secret), but
  /// username and password are reported as booleans only — they may
  /// identify the user or unlock the proxy and must never appear in logs.
  String describeForLogs() {
    final t = type.toString().split('.').last;
    final a = address ?? '<none>';
    return 'type=$t address=$a hasUsername=${username != null && username!.isNotEmpty} '
        'hasPassword=${password != null && password!.isNotEmpty} '
        'exitCountry=${torExitCountry ?? '<any>'}'
        '${type == ProxyType.SAVED ? ' saved=${savedProxyId ?? '<none>'}' : ''}'
        '${type == ProxyType.GATEWAY ? ' gateway=${gatewayId ?? '<none>'}' : ''}'
        '${credentialsId != null ? ' credentials=$credentialsId' : ''}';
  }

  bool get hasCredentials => username != null && username!.isNotEmpty && password != null && password!.isNotEmpty;
}
