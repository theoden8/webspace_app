// How an external tor's configuration differs from the built-in one's, read
// over its control port (TOR-026). Pure: the answers come in as values, the
// verdict goes out as one.

import 'package:webspace/services/tor_control.dart';

/// How a SocksPort splits streams into circuits, by the flags that change
/// what a site sees.
typedef TorSocksIsolation = ({
  bool bySocksAuth,
  bool byDestAddr,
  bool byDestPort,
});

/// The built-in tor's SocksPort, `auto IsolateSOCKSAuth`
/// (`TorControllerPlugin.socksPortValue`; test/external_tor_posture_test.dart
/// holds the two together).
const TorSocksIsolation kBuiltInTorIsolation =
    (bySocksAuth: true, byDestAddr: false, byDestPort: false);

/// The built-in tor's `SafeLogging`.
const String kBuiltInTorSafeLogging = '1';

/// One way the external tor treats sites differently from the built-in one.
sealed class TorPostureGap {
  const TorPostureGap();
}

/// `NoIsolateSOCKSAuth`: every site's credential lands on the same circuits,
/// so two sites can be linked by the exit they arrive from.
final class TorSharedCircuits extends TorPostureGap {
  const TorSharedCircuits();
}

/// `IsolateDestAddr`: a circuit per destination host as well, so a page
/// whose parts live on several hosts arrives from several exits.
final class TorPerDestinationHost extends TorPostureGap {
  const TorPerDestinationHost();
}

/// `IsolateDestPort`: a circuit per destination port as well.
final class TorPerDestinationPort extends TorPostureGap {
  const TorPerDestinationPort();
}

/// The tor's own `ExitNodes`, which every site the app has not pinned exits
/// through.
final class TorOwnExits extends TorPostureGap {
  const TorOwnExits(this.nodes);

  final String nodes;
}

/// `SafeLogging` other than 1: tor's log names the hosts sites reach.
final class TorLogsAddresses extends TorPostureGap {
  const TorLogsAddresses();
}

/// The SOCKS address is one of the tor's listeners, but no SocksPort line
/// can be told apart as the one it came from (several `auto` lines), so its
/// flags are unknown.
final class TorSocksFlagsUnknown extends TorPostureGap {
  const TorSocksFlagsUnknown();
}

/// What the control port said, as read for [judgeExternalTor].
final class ExternalTorConfig {
  const ExternalTorConfig({
    required this.socksPorts,
    required this.socksListeners,
    required this.exitNodes,
    required this.safeLogging,
  });

  /// Every `SocksPort` value (GETCONF); null for one at its default.
  final List<String?> socksPorts;

  /// `net/listeners/socks`: where tor is listening now.
  final List<String> socksListeners;

  /// `ExitNodes` as tor's own configuration has it, or null for none.
  final String? exitNodes;

  /// `SafeLogging`, or null at its default.
  final String? safeLogging;
}

/// The verdict on an external tor's control port.
sealed class ExternalTorPosture {
  const ExternalTorPosture();
}

/// The control port is that tor's, and [gaps] is how it differs, empty when
/// it treats sites as the built-in tor would.
final class TorPostureRead extends ExternalTorPosture {
  const TorPostureRead(this.gaps);

  final List<TorPostureGap> gaps;
}

/// The SOCKS address sites use is not among this tor's listeners: the
/// control port belongs to another tor, and nothing it says or does applies
/// to the sites.
final class TorPostureOtherTor extends ExternalTorPosture {
  const TorPostureOtherTor();
}

ExternalTorPosture judgeExternalTor(
  ExternalTorConfig config, {
  required String socksHost,
  required int socksPort,
}) {
  final host = _loopbackName(socksHost);
  final listening = config.socksListeners.any((listener) {
    final at = _hostPort(listener);
    return at != null &&
        at.port == socksPort &&
        (at.host == host || _isWildcard(at.host));
  });
  if (!listening) return const TorPostureOtherTor();

  final gaps = <TorPostureGap>[];
  final isolation = _isolationOf(config.socksPorts, host: host, port: socksPort);
  if (isolation == null) {
    gaps.add(const TorSocksFlagsUnknown());
  } else {
    if (isolation.bySocksAuth != kBuiltInTorIsolation.bySocksAuth) {
      gaps.add(const TorSharedCircuits());
    }
    if (isolation.byDestAddr != kBuiltInTorIsolation.byDestAddr) {
      gaps.add(const TorPerDestinationHost());
    }
    if (isolation.byDestPort != kBuiltInTorIsolation.byDestPort) {
      gaps.add(const TorPerDestinationPort());
    }
  }
  final exits = config.exitNodes;
  if (exits != null && exits.isNotEmpty) gaps.add(TorOwnExits(exits));
  if ((config.safeLogging ?? kBuiltInTorSafeLogging) != kBuiltInTorSafeLogging) {
    gaps.add(const TorLogsAddresses());
  }
  return TorPostureRead(gaps);
}

/// The flags of the SocksPort line [host]:[port] was opened from, or null
/// when no line can be told to be it.
TorSocksIsolation? _isolationOf(List<String?> lines,
    {required String host, required int port}) {
  final parsed = [
    for (final line in lines.isEmpty ? const <String?>[null] : lines)
      _SocksPortLine.parse(line),
  ];
  final exact = parsed.where((l) => l.serves(host: host, port: port)).toList();
  if (exact.length == 1) return exact.single.isolation;
  if (exact.isEmpty) {
    final auto = parsed.where((l) => l.isAuto).toList();
    if (auto.length == 1) return auto.single.isolation;
  }
  return null;
}

/// One SocksPort value: what it listens on and its isolation flags.
final class _SocksPortLine {
  const _SocksPortLine({required this.listen, required this.flags});

  /// [value] null is the option at its default, `9050` with no flags.
  factory _SocksPortLine.parse(String? value) {
    final words = (value ?? '9050').trim().split(RegExp(r'\s+'));
    return _SocksPortLine(
      listen: words.first,
      flags: {for (final w in words.skip(1)) w.toLowerCase()},
    );
  }

  final String listen;
  final Set<String> flags;

  bool get isAuto => listen.toLowerCase() == 'auto';

  bool serves({required String host, required int port}) {
    if (listen.startsWith('unix:') || isAuto) return false;
    final bare = int.tryParse(listen);
    if (bare != null) return bare == port && host == '127.0.0.1';
    final at = _hostPort(listen);
    if (at == null) return false;
    return at.port == port && (at.host == host || _isWildcard(at.host));
  }

  TorSocksIsolation get isolation => (
        bySocksAuth: !flags.contains('noisolatesocksauth'),
        byDestAddr: flags.contains('isolatedestaddr'),
        byDestPort: flags.contains('isolatedestport'),
      );
}

({String host, int port})? _hostPort(String value) {
  final at = TorControlEndpoint.parse(value);
  if (at is! TorControlTcp) return null;
  var host = at.host;
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return (host: _loopbackName(host), port: at.port);
}

String _loopbackName(String host) => host == 'localhost' ? '127.0.0.1' : host;

bool _isWildcard(String host) => host == '0.0.0.0' || host == '::';
