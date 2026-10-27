// The app's authenticated control connection to an external tor (TOR-026):
// what it says about that tor's configuration, and the commands that give
// the external tor what the built-in one has (new circuits, a strict exit
// country). No dart:io: the channel is an interface, opened by
// tor_control_io.dart in the app and by a fake tor in tests.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:webspace/services/external_tor_posture_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_engine.dart'
    show TorExitCountryEmpty, TorExitPinUnsupported;
import 'package:webspace/utils/concurrency.dart';

/// An open control connection that has not authenticated yet.
abstract interface class TorControlChannel {
  /// Sends [command], one line without its CRLF, and completes with tor's
  /// reply. Throws [TorControlClosed] once the channel is gone.
  Future<TorControlReply> send(String command);

  /// tor's asynchronous events, in order.
  Stream<TorControlReply> get events;

  /// Completes when the channel closes, from either end.
  Future<void> get done;

  Future<void> close();
}

typedef TorControlConnect = Future<TorControlChannel> Function(
    TorControlEndpoint endpoint);

/// The bytes of the file at [path], or null when it cannot be read.
typedef TorCookieRead = Future<Uint8List?> Function(String path);

/// How long one command may take. A channel that stops answering must fail
/// a pin well inside the engine's own deadline (kTorExitPinApplyTimeout),
/// so the failure names the external tor rather than a fault of the app.
const Duration kTorControlCommandTimeout = Duration(seconds: 10);

/// What the link reports after it is attached.
sealed class TorControlLinkEvent {
  const TorControlLinkEvent();
}

/// The tor's configuration changed and was read again.
final class TorLinkPostureChanged extends TorControlLinkEvent {
  const TorLinkPostureChanged(this.posture);

  final TorPostureRead posture;
}

/// The link is no use any more: the channel closed, or something else
/// changed the exit configuration the app's pin put in force. Whatever the
/// sites were promised has to be established again on a new link.
final class TorLinkLost extends TorControlLinkEvent {
  const TorLinkLost(this.reason);

  final String reason;
}

/// [TorControlLink.attach]'s answer.
sealed class TorControlAttach {
  const TorControlAttach();
}

final class TorControlLinked extends TorControlAttach {
  const TorControlLinked(this.link);

  final TorControlLink link;
}

final class TorControlNotLinked extends TorControlAttach {
  const TorControlNotLinked(this.refusal, {required this.detail});

  final TorControlRefusal refusal;
  final String detail;
}

/// The values a pin changes, as they were before it, for putting back.
typedef _ExitConfig = ({
  String? exitNodes,
  String? strictNodes,
  String? confluxEnabled,
});

const List<String> _exitKeys = ['ExitNodes', 'StrictNodes', 'ConfluxEnabled'];

/// An authenticated control connection to the tor behind the SOCKS address.
final class TorControlLink {
  TorControlLink._({
    required TorControlChannel channel,
    required this.version,
    required TorPostureRead posture,
    required _ExitConfig original,
    required ({String host, int port}) socks,
  })  : _channel = channel,
        _posture = posture,
        _original = original,
        _socks = socks;

  final TorControlChannel _channel;
  final ({String host, int port}) _socks;

  /// tor's version, from PROTOCOLINFO.
  final String? version;

  TorPostureRead _posture;
  TorPostureRead get posture => _posture;

  /// What the exit options were before the app pinned anything. Updated
  /// when something else changes them while no pin is in force.
  _ExitConfig _original;

  /// The pin in force, or null.
  String? _pinned;

  /// What the exit options should read now, so a CONF_CHANGED that says
  /// otherwise is told from the app's own.
  _ExitConfig get _expected => switch (_pinned) {
        null => _original,
        final pin => (exitNodes: pin, strictNodes: '1', confluxEnabled: '0'),
      };

  final SerialQueue _queue = SerialQueue('torControlLink');
  final StreamController<TorControlLinkEvent> _changes =
      StreamController<TorControlLinkEvent>.broadcast();
  StreamSubscription<TorControlReply>? _eventSub;
  bool _closed = false;

  /// Set once the link stopped speaking for the sites. A pin is not put
  /// back then: the channel is gone, or something else now owns the exit
  /// options.
  bool _lost = false;

  Stream<TorControlLinkEvent> get changes => _changes.stream;

  /// Authenticate on [channel] and read the tor behind it. On anything but
  /// [TorControlLinked] the channel is closed.
  static Future<TorControlAttach> attach({
    required TorControlChannel channel,
    required String? password,
    required TorCookieRead readCookie,
    required ({String host, int port}) socks,
  }) async {
    Future<TorControlNotLinked> refuse(TorControlRefusal refusal,
        {required String detail}) async {
      await channel.close();
      return TorControlNotLinked(refusal, detail: detail);
    }

    try {
      final info = TorProtocolInfo.fromReply(
          await _bounded(channel.send('PROTOCOLINFO 1')));
      if (info == null) {
        return refuse(TorControlRefusal.notTor,
            detail: 'It did not answer PROTOCOLINFO as tor.');
      }
      final cookieFile = info.cookieFile;
      final cookie = info.wantsCookie && cookieFile != null
          ? await readCookie(cookieFile)
          : null;
      final plan = planTorAuth(info: info, password: password, cookie: cookie);
      final authenticated = await _authenticate(channel, plan: plan);
      if (authenticated != null) {
        return refuse(authenticated, detail: switch (authenticated) {
          TorControlRefusal.cookieUnreadable =>
            'tor wants its cookie, and ${cookieFile ?? 'its cookie file'} '
                'cannot be read.',
          TorControlRefusal.needsPassword =>
            'tor wants a password, and none is saved.',
          _ => 'tor refused the authentication.',
        });
      }

      final read = await _readConfig(channel);
      final verdict = judgeExternalTor(read.config,
          socksHost: socks.host, socksPort: socks.port);
      switch (verdict) {
        case TorPostureOtherTor():
          return refuse(TorControlRefusal.otherTor,
              detail: 'That tor listens for SOCKS on '
                  '${read.config.socksListeners.join(', ')}, not on '
                  '${socks.host}:${socks.port}.');
        case TorPostureRead():
          final link = TorControlLink._(
            channel: channel,
            version: info.version,
            posture: verdict,
            original: read.exits,
            socks: socks,
          );
          await link._subscribe();
          return TorControlLinked(link);
      }
    } on TorControlClosed {
      return refuse(TorControlRefusal.unreachable,
          detail: 'The control channel closed while the app was attaching.');
    } on TimeoutException {
      return refuse(TorControlRefusal.unreachable,
          detail: 'The control port did not answer in time.');
    } on TorControlRejected catch (e) {
      return refuse(TorControlRefusal.notTor, detail: '$e');
    } on FormatException catch (e) {
      return refuse(TorControlRefusal.notTor, detail: e.message);
    }
  }

  /// Null once authenticated, else why not.
  static Future<TorControlRefusal?> _authenticate(TorControlChannel channel,
      {required TorAuthPlan plan}) async {
    final String command;
    switch (plan) {
      case TorAuthImpossible(:final refusal):
        return refusal;
      case TorAuthNull():
        command = 'AUTHENTICATE';
      case TorAuthPassword(:final password):
        command = 'AUTHENTICATE ${torQuoted(password)}';
      case TorAuthSafeCookie(:final cookie):
        final rng = Random.secure();
        final clientNonce = List<int>.generate(32, (_) => rng.nextInt(256));
        final challenge = TorSafeCookieExchange.challengeOf(await _bounded(
            channel.send('AUTHCHALLENGE SAFECOOKIE ${hexOf(clientNonce)}')));
        if (challenge == null) return TorControlRefusal.refused;
        final exchange = TorSafeCookieExchange(
          cookie: cookie,
          clientNonce: clientNonce,
          serverNonce: challenge.nonce,
        );
        // A listener that cannot produce this did not read the cookie: it
        // is not that tor, and gets no proof of the app reading it either.
        if (!sameBytes(exchange.serverHash, other: challenge.hash)) {
          return TorControlRefusal.refused;
        }
        command = 'AUTHENTICATE ${hexOf(exchange.clientHash)}';
    }
    final reply = await _bounded(channel.send(command));
    return reply.isOk ? null : TorControlRefusal.refused;
  }

  /// The SocksPort and logging answers the posture is judged on, and the
  /// exit options a pin would change.
  static Future<({ExternalTorConfig config, _ExitConfig exits})> _readConfig(
      TorControlChannel channel) async {
    final listeners = _expectOk(
        await _bounded(channel.send('GETINFO net/listeners/socks')),
        command: 'GETINFO');
    final conf = _expectOk(
        await _bounded(channel.send(
            'GETCONF SocksPort SafeLogging ${_exitKeys.join(' ')}')),
        command: 'GETCONF');
    final values = torKeyValues(conf);
    String? one(String key) {
      final v = values[key]?.firstOrNull;
      return (v == null || v.isEmpty) ? null : v;
    }

    final listenerValue =
        torKeyValues(listeners)['net/listeners/socks']?.firstOrNull ?? '';
    return (
      config: ExternalTorConfig(
        socksPorts: values['SocksPort'] ?? const [],
        socksListeners: torQuotedList(listenerValue),
        exitNodes: one('ExitNodes'),
        safeLogging: one('SafeLogging'),
      ),
      exits: (
        exitNodes: one('ExitNodes'),
        strictNodes: one('StrictNodes'),
        confluxEnabled: one('ConfluxEnabled'),
      ),
    );
  }

  Future<void> _subscribe() async {
    _eventSub = _channel.events.listen(_onEvent);
    unawaited(_channel.done.then((_) => _lose('The control channel closed.')));
    _expectOk(await _bounded(_channel.send('SETEVENTS CONF_CHANGED')),
        command: 'SETEVENTS');
  }

  void _onEvent(TorControlReply event) {
    if (event.lines.isEmpty || event.lines.first != 'CONF_CHANGED') return;
    final changed = torKeyValues(
        TorControlReply(status: 250, lines: event.lines.skip(1).toList()));
    String? now(String key) {
      final v = changed[key]?.lastOrNull;
      return (v == null || v.isEmpty) ? null : v;
    }

    final expected = _expected;
    final foreign = (changed.containsKey('ExitNodes') &&
            now('ExitNodes') != expected.exitNodes) ||
        (changed.containsKey('StrictNodes') &&
            now('StrictNodes') != expected.strictNodes) ||
        (changed.containsKey('ConfluxEnabled') &&
            now('ConfluxEnabled') != expected.confluxEnabled);
    if (foreign && _pinned != null) {
      // A reload or another controller put tor's own exits back under the
      // pin the sites were promised.
      _lose('Something else changed the exit configuration the app had '
          'pinned.');
      return;
    }
    unawaited(_queue.run(_reread));
  }

  Future<void> _reread() async {
    if (_closed) return;
    try {
      final read = await _readConfig(_channel);
      if (_pinned == null) _original = read.exits;
      // Judged on tor's own exits, not the app's pin over them.
      final config = ExternalTorConfig(
        socksPorts: read.config.socksPorts,
        socksListeners: read.config.socksListeners,
        exitNodes: _original.exitNodes,
        safeLogging: read.config.safeLogging,
      );
      final verdict = judgeExternalTor(config,
          socksHost: _socks.host, socksPort: _socks.port);
      switch (verdict) {
        case TorPostureOtherTor():
          _lose('That tor no longer listens on the SOCKS address sites use.');
        case TorPostureRead():
          _posture = verdict;
          if (!_changes.isClosed) _changes.add(TorLinkPostureChanged(verdict));
      }
    } on TorControlClosed {
      _lose('The control channel closed.');
    } on TimeoutException {
      _lose('The control port stopped answering.');
    } on TorControlRejected catch (e) {
      _lose('$e');
    }
  }

  void _lose(String reason) {
    if (_closed || _lost) return;
    _lost = true;
    LogTag.tor.debug('External control link lost: $reason');
    if (!_changes.isClosed) _changes.add(TorLinkLost(reason));
  }

  /// `SIGNAL NEWNYM`: fresh circuits for new streams. tor rate-limits it on
  /// its own.
  Future<void> newCircuits() => _queue.run(() async {
        _expectOk(await _bounded(_channel.send('SIGNAL NEWNYM')),
            command: 'SIGNAL');
      });

  /// Pin exits to [exitNodes] with StrictNodes, or put back what tor had
  /// before when null, as the built-in tor does (TOR-014): GeoIP and an
  /// exit in the country checked first, conflux off for the pin's life,
  /// exit circuits from before the change closed.
  ///
  /// Throws [TorExitCountryEmpty] for a country with no exit and
  /// [TorExitPinUnsupported] for a tor that cannot take a pin from here.
  Future<void> pin(String? exitNodes) => _queue.run(() async {
        try {
          await _pin(exitNodes);
        } on TorControlClosed {
          throw const TorExitPinUnsupported(
              "The external tor's control channel closed while the exit "
              'country was being changed, so the change is not in force.');
        } on TimeoutException {
          throw const TorExitPinUnsupported(
              "The external tor's control port stopped answering while the "
              'exit country was being changed, so the change is not in '
              'force.');
        } on TorControlRejected catch (e) {
          throw TorExitPinUnsupported(
              'The external tor refused the exit-country change ($e).');
        }
      });

  Future<void> _pin(String? exitNodes) async {
    if (exitNodes == _pinned) return;
    if (exitNodes == null) {
      await _withPinned(null, send: _restore);
      await _closeExitCircuits();
      return;
    }
    final geoip = torKeyValues(_expectOk(
        await _bounded(_channel.send('GETINFO ip-to-country/ipv4-available')),
        command: 'GETINFO'));
    if (geoip['ip-to-country/ipv4-available']?.firstOrNull != '1') {
      throw const TorExitPinUnsupported(
          'The external tor has no GeoIP data loaded, so it cannot tell '
          'which country an exit is in. On Debian and Ubuntu it comes with '
          'the tor-geoipdb package.');
    }
    final countries = torPinnedCountries(exitNodes);
    if (countries != null && await _hasNoExitIn(countries)) {
      final names = (countries.toList()..sort())
          .map((c) => c.toUpperCase())
          .join(', ');
      throw TorExitCountryEmpty(
          "The external tor's consensus lists no exit relay in $names, so "
          'no circuit could be built under this exit-country pin, and it was '
          'not applied. Sites pinned there stay blocked: nothing leaves from '
          'another country instead.');
    }
    await _withPinned(exitNodes, send: () async {
      _expectOk(
          await _bounded(_channel.send('SETCONF ExitNodes=${torQuoted(exitNodes)} '
              'StrictNodes=1 ConfluxEnabled=0')),
          command: 'SETCONF');
    });
    await _closeExitCircuits();
  }

  /// Runs [send] with [_pinned] already at [pin], so the CONF_CHANGED it
  /// causes reads as the app's own, and puts the old value back when tor
  /// did not take it.
  Future<void> _withPinned(String? pin,
      {required Future<void> Function() send}) async {
    final previous = _pinned;
    _pinned = pin;
    try {
      await send();
    } on TorControlClosed {
      _pinned = previous;
      rethrow;
    } on TimeoutException {
      _pinned = previous;
      rethrow;
    } on TorControlRejected {
      _pinned = previous;
      rethrow;
    } on FormatException {
      _pinned = previous;
      rethrow;
    }
  }

  /// Puts the exit options back as they were before the first pin.
  Future<void> _restore() async {
    final original = _original;
    final values = {
      'ExitNodes': original.exitNodes,
      'StrictNodes': original.strictNodes,
      'ConfluxEnabled': original.confluxEnabled,
    };
    final reset = [
      for (final e in values.entries)
        if (e.value == null) e.key,
    ];
    final set = [
      for (final e in values.entries)
        if (e.value != null) '${e.key}=${torQuoted(e.value!)}',
    ];
    if (reset.isNotEmpty) {
      _expectOk(await _bounded(_channel.send('RESETCONF ${reset.join(' ')}')),
          command: 'RESETCONF');
    }
    if (set.isNotEmpty) {
      _expectOk(await _bounded(_channel.send('SETCONF ${set.join(' ')}')),
          command: 'SETCONF');
    }
  }

  /// Whether the consensus has exits and none of them is in [countries] by
  /// tor's own GeoIP. False when it cannot tell, as the built-in tor does:
  /// the pin is then applied and a country with no exit fails visibly.
  Future<bool> _hasNoExitIn(Set<String> countries) async {
    // Megabytes of consensus; still loopback, and well inside the pin's
    // own deadline.
    final ns = torKeyValues(_expectOk(
        await _bounded(_channel.send('GETINFO ns/all'),
            within: const Duration(seconds: 15)),
        command: 'GETINFO'));
    final exits = torExitAddresses(ns['ns/all']?.firstOrNull ?? '');
    if (exits.isEmpty) return false;
    const batch = 64;
    for (var i = 0; i < exits.length; i += batch) {
      final keys = [
        for (final ip in exits.skip(i).take(batch)) 'ip-to-country/$ip',
      ];
      final answers = torKeyValues(_expectOk(
          await _bounded(_channel.send('GETINFO ${keys.join(' ')}')),
          command: 'GETINFO'));
      for (final values in answers.values) {
        if (countries.contains(values.firstOrNull?.toLowerCase())) return false;
      }
    }
    return true;
  }

  /// Ends the streams opened before an exit change: tor stops attaching
  /// new streams to old circuits on its own, and keeps the open ones.
  Future<void> _closeExitCircuits() async {
    final status = torKeyValues(_expectOk(
        await _bounded(_channel.send('GETINFO circuit-status')),
        command: 'GETINFO'));
    for (final id
        in torExitCircuitIds(status['circuit-status']?.firstOrNull ?? '')) {
      // 552 for a circuit that closed in the meantime.
      await _bounded(_channel.send('CLOSECIRCUIT $id'));
    }
  }

  /// Puts back any pin the app left in force, then closes the channel.
  Future<void> close() async {
    if (_closed) return;
    if (!_lost) {
      try {
        await pin(null);
      } on TorExitPinUnsupported catch (e) {
        LogTag.tor.debug("Could not put the external tor's exits back: $e");
      }
    }
    _closed = true;
    await _eventSub?.cancel();
    await _channel.close();
    await _changes.close();
  }

  static Future<TorControlReply> _bounded(Future<TorControlReply> reply,
          {Duration within = kTorControlCommandTimeout}) =>
      reply.timeout(within);

  static TorControlReply _expectOk(TorControlReply reply,
      {required String command}) {
    if (!reply.isOk) throw TorControlRejected(reply, command: command);
    return reply;
  }
}

/// Circuit purposes that carry streams out through an exit.
const Set<String> _exitCapablePurposes = {
  'GENERAL',
  'CONFLUX_LINKED',
  'CONFLUX_UNLINKED',
};

/// A circuit's id as tor's control port names it: letters and digits only,
/// so one interpolated into a command cannot carry a second.
extension type TorCircuitId._(String raw) implements String {
  static final _shape = RegExp(r'^[A-Za-z0-9]+$');

  static TorCircuitId? parse(String word) =>
      _shape.hasMatch(word) ? TorCircuitId._(word) : null;
}

/// IDs of the circuits a `circuit-status` value lists as able to carry exit
/// traffic (`TorControllerPlugin.exitCircuitIds`).
List<TorCircuitId> torExitCircuitIds(String raw) {
  final out = <TorCircuitId>[];
  for (final line in raw.split('\n')) {
    final words = line.trim().split(' ');
    if (words.length < 2) continue;
    final id = TorCircuitId.parse(words[0]);
    if (id == null) continue;
    if (words[1] == 'CLOSED' || words[1] == 'FAILED') continue;
    final purpose = RegExp(r'(?:^| )PURPOSE=(\S+)').firstMatch(line)?.group(1);
    if (purpose != null && !_exitCapablePurposes.contains(purpose)) continue;
    out.add(id);
  }
  return out;
}

/// Lowercased country codes an `ExitNodes` value names, or null when it
/// names anything but countries (`TorControllerPlugin.pinnedCountries`).
Set<String>? torPinnedCountries(String exitNodes) {
  final out = <String>{};
  for (final item in exitNodes.split(',')) {
    final code = item.trim();
    if (code.length != 4 || !code.startsWith('{') || !code.endsWith('}')) {
      return null;
    }
    out.add(code.substring(1, 3).toLowerCase());
  }
  return out.isEmpty ? null : out;
}

/// IPv4 address of every relay an `ns/all` value lists with Exit and
/// without BadExit (`TorControllerPlugin.exitAddresses`).
List<String> torExitAddresses(String raw) {
  final out = <String>[];
  String? address;
  for (final line in raw.split('\n')) {
    if (line.startsWith('r ')) {
      final words = line.split(' ');
      final candidate = words.length >= 8 ? words[words.length - 3] : '';
      address = candidate.split('.').length == 4 ? candidate : null;
    } else if (line.startsWith('s ') && address != null) {
      final flags = line.split(' ').toSet();
      if (flags.contains('Exit') && !flags.contains('BadExit')) {
        out.add(address);
      }
      address = null;
    }
  }
  return out;
}
