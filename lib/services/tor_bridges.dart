// Pluggable-transport configuration: what a bridge line is, and what tor
// has to be told to use one.
//
// Censorship is the failure the user can actually act on (TOR-015
// `censored`), and bridges are the action. Everything decidable without a
// running tor lives here as pure Dart — parsing a pasted bridge line,
// rejecting a malformed one, and generating the torrc lines — so the Swift
// side is left applying an already-tested configuration rather than being
// the place the logic lives.
//
// Spec: openspec/specs/tor-proxy/spec.md (TOR-016 bridges).

import 'package:webspace/services/tor_failure.dart' show TorFailureKind;

/// Transports IPtProxy 5.x can run. The wire names are tor's, and are what
/// both `ClientTransportPlugin` and the first token of a bridge line use, so
/// they are not free to rename.
enum TorTransport {
  /// Lyrebird's obfs4. The default: needs a bridge line, hardest to block.
  obfs4('obfs4'),

  /// Snowflake. The app carries a built-in line, so the user need not
  /// supply one.
  snowflake('snowflake'),

  /// Lyrebird's meek_lite, domain-fronted. Slow; a last resort.
  meekLite('meek_lite'),

  /// Lyrebird's webtunnel, looks like ordinary HTTPS.
  webtunnel('webtunnel');

  const TorTransport(this.wireName);

  /// tor's name for the transport. Used verbatim in torrc.
  final String wireName;

  static TorTransport? fromWireName(String name) {
    for (final t in TorTransport.values) {
      if (t.wireName == name) return t;
    }
    return null;
  }

  /// Whether BridgeDB hands out bridges for this transport over Moat.
  ///
  /// obfs4 and webtunnel only. Asking for snowflake or meek_lite is not an
  /// empty answer but an HTTP 400 "Not valid request" — they are not
  /// allocated per user at all, they use one published line each. Offering
  /// the fetch button for them would offer a request that cannot succeed.
  bool get moatDistributes =>
      this == TorTransport.obfs4 || this == TorTransport.webtunnel;

  /// The published line to use when the user supplied none, or null when
  /// this transport needs one of their own.
  ///
  /// Snowflake and meek_lite are the two that are not allocated per user:
  /// there is one public bridge for each, and its parameters ride the line
  /// as SOCKS arguments. No transport works with *no* bridge line — these
  /// two work with a line the app already knows.
  String? get builtInLine => switch (this) {
        TorTransport.snowflake => kBuiltInSnowflakeBridge,
        TorTransport.meekLite => kBuiltInMeekBridge,
        _ => null,
      };

  /// Whether the user can leave the bridge-line list empty for this
  /// transport, because [builtInLine] stands in.
  bool get worksWithoutBridgeLine => builtInLine != null;
}

/// The snowflake bridge used when the user supplied none.
///
/// Snowflake's rendezvous parameters — broker URL, domain fronts, STUN
/// servers — ride the bridge line as SOCKS arguments, and IPtProxy's
/// `Controller` defaults every one of them to the empty string. So
/// `UseBridges 1` with a snowflake `ClientTransportPlugin` and no `Bridge`
/// line does not fall back to a working default; it leaves tor with
/// nothing to dial. This is the Tor Project's published built-in line, the
/// one Tor Browser ships.
const String kBuiltInSnowflakeBridge =
    'snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 '
    'fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 '
    'url=https://1098762253.rsc.cdn77.org/ '
    'fronts=app.datapacket.com,www.datapacket.com '
    'ice=stun:stun.epygi.com:3478,stun:stun.uls.co.za:3478,'
    'stun:stun.voipgate.com:3478,stun:stun.mixvoip.com:3478,'
    'stun:stun.telnyx.com:3478,stun:stun.hot-chilli.net:3478,'
    'stun:stun.fitauto.ru:3478,stun:stun.m-online.net:3478 '
    'utls-imitate=hellorandomizedalpn';

/// The meek bridge used when the user supplied none.
///
/// Same reasoning as the snowflake line: meek is domain-fronted, its front
/// and CDN URL ride the line as SOCKS arguments, and BridgeDB does not
/// allocate meek bridges per user. This is the published line. Note it is
/// no longer the old meek-azure one — that fronting path is dead.
const String kBuiltInMeekBridge =
    'meek_lite 192.0.2.20:80 url=https://1603026938.rsc.cdn77.org '
    'front=www.phpmyadmin.net utls=HelloRandomizedALPN';

/// One parsed bridge line.
///
/// Deliberately not modelled field-by-field beyond the transport: the tail
/// of a bridge line is transport-defined (obfs4 carries `cert=` and
/// `iat-mode=`, webtunnel a `url=`, meek a `url=` and `front=`) and tor is
/// the authority on it. Re-serialising from parsed parts would risk
/// corrupting a line the user pasted correctly, so the original text is
/// kept verbatim and only its shape is checked.
class TorBridgeLine {
  const TorBridgeLine({required this.transport, required this.raw});

  final TorTransport transport;

  /// The line exactly as the user supplied it, minus surrounding space and
  /// any leading `Bridge ` keyword.
  final String raw;

  @override
  String toString() => raw;

  @override
  bool operator ==(Object other) =>
      other is TorBridgeLine && other.raw == raw && other.transport == transport;

  @override
  int get hashCode => Object.hash(transport, raw);
}

/// Why a pasted line was rejected. Each maps to its own message, because
/// "invalid bridge" tells someone who pasted a half-copied line nothing.
enum TorBridgeParseError {
  /// Nothing but whitespace.
  empty,

  /// First token is not a transport we can run.
  unknownTransport,

  /// Transport is known but the address that must follow is missing or is
  /// not `host:port`.
  malformedAddress,

  /// obfs4 without the `cert=` it cannot connect without. Catching this
  /// here turns a silent bootstrap failure into an immediate explanation.
  missingCertificate,
}

/// Result of parsing one line: exactly one of [line] or [error] is set.
class TorBridgeParseResult {
  const TorBridgeParseResult.ok(this.line) : error = null;
  const TorBridgeParseResult.failed(this.error) : line = null;

  final TorBridgeLine? line;
  final TorBridgeParseError? error;

  bool get isOk => line != null;
}

final RegExp _hostPort = RegExp(r'^\[?[^\s\]]+\]?:\d{1,5}$');

/// Parse one bridge line.
///
/// Accepts the forms people actually paste: with or without a leading
/// `Bridge ` keyword, and — for obfs4 and friends — with the transport name
/// first. A bare `host:port` with no transport is *not* accepted: that is a
/// vanilla bridge, which needs `UseBridges` without a transport plugin, and
/// silently treating it as obfs4 would produce a configuration that cannot
/// work.
TorBridgeParseResult parseTorBridgeLine(String input) {
  var s = input.trim();
  if (s.isEmpty) return const TorBridgeParseResult.failed(TorBridgeParseError.empty);

  // Tolerate a copied torrc line. The bare keyword with nothing after it is
  // an empty line, not a transport named "Bridge": trimming happens first,
  // so "Bridge   " arrives here as the lone word.
  final lower = s.toLowerCase();
  if (lower == 'bridge') {
    return const TorBridgeParseResult.failed(TorBridgeParseError.empty);
  }
  if (lower.startsWith('bridge ')) s = s.substring(7).trim();
  if (s.isEmpty) return const TorBridgeParseResult.failed(TorBridgeParseError.empty);

  final parts = s.split(RegExp(r'\s+'));
  final transport = TorTransport.fromWireName(parts.first);
  if (transport == null) {
    return const TorBridgeParseResult.failed(
        TorBridgeParseError.unknownTransport);
  }

  // Snowflake's published line carries no address — its rendezvous options
  // are the rest of the line — so only require an address for the others.
  if (transport != TorTransport.snowflake) {
    if (parts.length < 2 || !_hostPort.hasMatch(parts[1])) {
      return const TorBridgeParseResult.failed(
          TorBridgeParseError.malformedAddress);
    }
  }

  if (transport == TorTransport.obfs4 &&
      !parts.any((p) => p.startsWith('cert='))) {
    return const TorBridgeParseResult.failed(
        TorBridgeParseError.missingCertificate);
  }

  return TorBridgeParseResult.ok(
      TorBridgeLine(transport: transport, raw: s));
}

/// A complete bridge configuration: which transport to run, and the lines to
/// feed tor.
class TorBridgeConfig {
  const TorBridgeConfig({
    this.enabled = false,
    this.transport = TorTransport.obfs4,
    this.lines = const [],
  });

  /// Off by default. Bridges are slower than direct guards, so they are for
  /// people who need them, not a default posture.
  final bool enabled;
  final TorTransport transport;
  final List<TorBridgeLine> lines;

  /// Whether this configuration can actually be handed to tor. A transport
  /// that needs bridge lines and has none would leave tor with `UseBridges 1`
  /// and nothing to dial, which fails with no useful message.
  bool get isUsable {
    if (!enabled) return true;
    if (transport.worksWithoutBridgeLine) return true;
    return lines.any((l) => l.transport == transport);
  }

  TorBridgeConfig copyWith({
    bool? enabled,
    TorTransport? transport,
    List<TorBridgeLine>? lines,
  }) =>
      TorBridgeConfig(
        enabled: enabled ?? this.enabled,
        transport: transport ?? this.transport,
        lines: lines ?? this.lines,
      );

  /// Serialised form for secure storage.
  ///
  /// There is deliberately no path from here into settings export: bridge
  /// lines live only in `flutter_secure_storage`, never in SharedPreferences
  /// and never in `kExportedAppPrefs`. A privately-allocated obfs4 bridge
  /// identifies its user, and a backup file gets mailed and synced
  /// (the reasoning behind PWD-005, applied to a different secret).
  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'transport': transport.wireName,
        'lines': lines.map((l) => l.raw).toList(),
      };

  /// Rebuild from stored JSON, re-parsing each line rather than trusting it.
  ///
  /// The store is on-device and encrypted, but it is still input: a line
  /// that no longer parses (a transport we dropped, a truncated write) is
  /// discarded rather than handed to tor, which would fail the whole
  /// configuration and take the working lines down with it.
  static TorBridgeConfig fromJson(Map<String, Object?> json) {
    final transport =
        TorTransport.fromWireName(json['transport'] as String? ?? '') ??
            TorTransport.obfs4;
    final raw = json['lines'];
    final lines = <TorBridgeLine>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! String) continue;
        final parsed = parseTorBridgeLine(entry);
        if (parsed.isOk) lines.add(parsed.line!);
      }
    }
    return TorBridgeConfig(
      enabled: json['enabled'] == true,
      transport: transport,
      lines: lines,
    );
  }
}

/// The torrc options that put [config] into force, given the local SOCKS
/// port IPtProxy reported for the transport.
///
/// Returned as ordered key/value pairs rather than a formatted string: the
/// Swift side hands them to `TorConfiguration.options`, and building a torrc
/// by string concatenation is how a stray newline becomes an injected
/// directive.
///
/// Returns empty when bridges are off or unusable — never a half
/// configuration, because `UseBridges 1` with no reachable bridge is
/// strictly worse than no bridges at all: it stops tor from using the
/// direct guards that might have worked.
List<(String, String)> torBridgeOptions(
  TorBridgeConfig config, {
  required int transportPort,
  String transportHost = '127.0.0.1',
}) {
  if (!config.enabled || !config.isUsable) return const [];
  if (transportPort <= 0) return const [];

  final t = config.transport;
  final out = <(String, String)>[
    ('UseBridges', '1'),
    (
      'ClientTransportPlugin',
      '${t.wireName} socks5 $transportHost:$transportPort',
    ),
  ];

  // Only the lines matching the selected transport: tor rejects a Bridge
  // line whose transport has no ClientTransportPlugin, and shipping the
  // others would fail the whole configuration rather than be ignored.
  final matching = config.lines.where((l) => l.transport == t).toList();
  for (final line in matching) {
    out.add(('Bridge', line.raw));
  }
  final builtIn = t.builtInLine;
  if (matching.isEmpty && builtIn != null) {
    out.add(('Bridge', builtIn));
  }
  return out;
}

/// Whether [kind] is a failure bridges could plausibly fix.
///
/// Drives whether the failure UI offers a route to bridge settings. Offering
/// it for a wrong clock or an unusable exit pin would send the user down a
/// road that cannot help.
bool bridgesMayHelp(TorFailureKind kind) =>
    kind == TorFailureKind.censored || kind == TorFailureKind.bootstrapTimeout;
