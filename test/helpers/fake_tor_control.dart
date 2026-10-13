import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_link.dart';

/// tor's side of a control connection, as far as the external tor's link
/// uses it (TOR-026): authentication refuses anything before it and closes
/// on a failure, the configuration answers GETCONF and changes under
/// SETCONF/RESETCONF with a CONF_CHANGED to subscribers, and a [reload]
/// puts the torrc back the way SIGHUP does. Replies are raw lines in tor's
/// framing, so whatever reads them parses what tor would send.
class FakeTorControl {
  FakeTorControl({
    Set<TorAuthMethod> methods = const {TorAuthMethod.none},
    this.cookieFile = '/run/tor/control.authcookie',
    this.password,
    List<int>? cookie,
    Map<String, List<String>>? torrc,
    this.socksListeners = const ['127.0.0.1:9050'],
    this.relays = const [],
    this.geoip = true,
  })  : methods = Set.of(methods),
        cookie = cookie ?? List<int>.generate(32, (i) => i),
        torrc = torrc ??
            {
              'SocksPort': ['9050'],
              'SafeLogging': ['1'],
              'StrictNodes': ['0'],
              'ConfluxEnabled': ['auto'],
            } {
    config = {for (final e in this.torrc.entries) e.key: List.of(e.value)};
  }

  final Set<TorAuthMethod> methods;
  final String cookieFile;
  final String? password;
  final List<int> cookie;

  /// What the configuration goes back to on [reload].
  final Map<String, List<String>> torrc;
  late Map<String, List<String>> config;
  List<String> socksListeners;

  /// (IPv4, country) of each exit relay the consensus lists.
  List<(String, String)> relays;
  bool geoip;

  /// Circuits tor reports, as `circuit-status` lines.
  List<String> circuits = const [];

  final commands = <String>[];
  final closedCircuits = <String>[];
  int newnyms = 0;

  void Function(List<String> lines)? _push;
  void Function()? _hangUp;
  bool _authenticated = false;
  bool _confChanged = false;
  List<int>? _clientNonce;
  List<int>? _serverNonce;

  /// A channel to this tor, as `openTorControl` would hand one out.
  FakeTorControlChannel connect() => FakeTorControlChannel(this);

  /// Serves this tor over a real connection: [push] writes lines tor sends
  /// unasked (events), [hangUp] closes the connection.
  void serveLines({
    required void Function(List<String> lines) push,
    required void Function() hangUp,
  }) {
    _push = push;
    _hangUp = hangUp;
  }

  /// SIGHUP: tor reads its torrc again, and what SETCONF set is gone.
  void reload() {
    final before = config;
    config = {for (final e in torrc.entries) e.key: List.of(e.value)};
    _announce({
      for (final key in {...before.keys, ...config.keys})
        if (!_same(before[key], other: config[key])) key,
    });
  }

  /// tor exits, or restarts.
  void hangUp() => _hangUp?.call();

  List<String> answer(String line) {
    commands.add(line);
    final space = line.indexOf(' ');
    final verb = (space < 0 ? line : line.substring(0, space)).toUpperCase();
    final args = space < 0 ? '' : line.substring(space + 1);
    if (!_authenticated &&
        !{'PROTOCOLINFO', 'AUTHENTICATE', 'AUTHCHALLENGE'}.contains(verb)) {
      _hangUpSoon();
      return ['514 Authentication required.'];
    }
    switch (verb) {
      case 'PROTOCOLINFO':
        return [
          '250-PROTOCOLINFO 1',
          '250-AUTH METHODS=${methods.map((m) => m.wireName).join(',')}'
              '${methods.any((m) => m == TorAuthMethod.cookie || m == TorAuthMethod.safeCookie) ? ' COOKIEFILE=${torQuoted(cookieFile)}' : ''}',
          '250-VERSION Tor="0.4.8.10"',
          '250 OK',
        ];
      case 'AUTHCHALLENGE':
        final nonce = hexBytes(args.split(' ').last)!;
        _clientNonce = nonce;
        _serverNonce = List<int>.generate(32, (i) => 255 - i);
        final hash = Hmac(sha256,
                ascii.encode('Tor safe cookie authentication server-to-controller hash'))
            .convert([...cookie, ...nonce, ..._serverNonce!]).bytes;
        return [
          '250 AUTHCHALLENGE SERVERHASH=${hexOf(hash)} '
              'SERVERNONCE=${hexOf(_serverNonce!)}'
        ];
      case 'AUTHENTICATE':
        if (_accepts(args)) {
          _authenticated = true;
          return ['250 OK'];
        }
        _hangUpSoon();
        return ['515 Authentication failed: wrong length or bad characters.'];
      case 'GETINFO':
        return _getinfo(args.split(' '));
      case 'GETCONF':
        final keys = args.split(' ');
        final lines = <String>[];
        for (final key in keys) {
          final values = config[key] ?? const [];
          if (values.isEmpty) {
            lines.add(key);
          } else {
            lines.addAll(values.map((v) => '$key=$v'));
          }
        }
        return [
          for (var i = 0; i < lines.length; i++)
            '250${i == lines.length - 1 ? ' ' : '-'}${lines[i]}',
        ];
      case 'SETCONF':
        final changes = _assignments(args);
        for (final e in changes.entries) {
          config[e.key] = e.value == null ? [] : [e.value!];
        }
        _announce(changes.keys.toSet());
        return ['250 OK'];
      case 'RESETCONF':
        final keys = args.split(' ').toSet();
        for (final key in keys) {
          config[key] = List.of(_defaults[key] ?? const []);
        }
        _announce(keys);
        return ['250 OK'];
      case 'SETEVENTS':
        _confChanged = args.split(' ').contains('CONF_CHANGED');
        return ['250 OK'];
      case 'SIGNAL':
        if (args == 'NEWNYM') newnyms++;
        return ['250 OK'];
      case 'CLOSECIRCUIT':
        closedCircuits.add(args);
        return ['250 OK'];
    }
    return ['510 Unrecognized command "$verb"'];
  }

  /// Built-in defaults, which RESETCONF goes back to.
  static const Map<String, List<String>> _defaults = {
    'ExitNodes': [],
    'StrictNodes': ['0'],
    'ConfluxEnabled': ['auto'],
  };

  bool _accepts(String args) {
    if (methods.contains(TorAuthMethod.none)) return true;
    if (args.startsWith('"')) {
      return methods.contains(TorAuthMethod.hashedPassword) &&
          password != null &&
          args == torQuoted(password!);
    }
    final bytes = hexBytes(args);
    if (bytes == null) return false;
    if (methods.contains(TorAuthMethod.safeCookie) &&
        _clientNonce != null &&
        _serverNonce != null) {
      final expected = Hmac(sha256,
              ascii.encode('Tor safe cookie authentication controller-to-server hash'))
          .convert([...cookie, ..._clientNonce!, ..._serverNonce!]).bytes;
      return sameBytes(bytes, other: expected);
    }
    return methods.contains(TorAuthMethod.cookie) &&
        sameBytes(bytes, other: cookie);
  }

  List<String> _getinfo(List<String> keys) {
    final lines = <String>[];
    for (final key in keys) {
      if (key == 'net/listeners/socks') {
        lines.add('250-$key=${socksListeners.map(torQuoted).join(' ')}');
      } else if (key == 'ip-to-country/ipv4-available') {
        lines.add('250-$key=${geoip ? 1 : 0}');
      } else if (key.startsWith('ip-to-country/')) {
        final ip = key.substring('ip-to-country/'.length);
        final country =
            relays.where((r) => r.$1 == ip).map((r) => r.$2).firstOrNull ?? '??';
        lines.add('250-$key=$country');
      } else if (key == 'ns/all') {
        lines.add('250+ns/all=');
        var n = 0;
        for (final (ip, _) in relays) {
          n++;
          lines.add('r relay$n AAAA BBBB 2026-10-13 00:00:00 $ip 9001 0');
          lines.add('s Exit Fast Running Stable Valid');
        }
        lines.add('.');
      } else if (key == 'circuit-status') {
        lines.add('250+circuit-status=');
        lines.addAll(circuits);
        lines.add('.');
      } else {
        return ['552 Unrecognized key "$key"'];
      }
    }
    lines.add('250 OK');
    return lines;
  }

  static Map<String, String?> _assignments(String args) {
    final out = <String, String?>{};
    var i = 0;
    while (i < args.length) {
      while (i < args.length && args[i] == ' ') {
        i++;
      }
      final end = args.indexOf(RegExp(r'[ =]'), i);
      final key = args.substring(i, end < 0 ? args.length : end);
      if (end < 0 || args[end] == ' ') {
        out[key] = null;
        i = end < 0 ? args.length : end;
        continue;
      }
      if (args[end + 1] == '"') {
        final close = args.indexOf('"', end + 2);
        out[key] = args.substring(end + 2, close);
        i = close + 1;
      } else {
        final space = args.indexOf(' ', end);
        out[key] = args.substring(end + 1, space < 0 ? args.length : space);
        i = space < 0 ? args.length : space;
      }
    }
    return out;
  }

  void _announce(Set<String> keys) {
    if (!_confChanged || keys.isEmpty) return;
    final lines = <String>['650-CONF_CHANGED'];
    for (final key in keys) {
      final values = config[key] ?? const [];
      if (values.isEmpty) {
        lines.add('650-$key');
      } else {
        lines.addAll(values.map((v) => '650-$key=$v'));
      }
    }
    lines.add('650 OK');
    _push?.call(lines);
  }

  void _hangUpSoon() => scheduleMicrotask(() => _hangUp?.call());

  static bool _same(List<String>? a, {required List<String>? other}) =>
      (a ?? const []).join('\n') == (other ?? const []).join('\n');
}

/// A [TorControlChannel] onto a [FakeTorControl], reading its lines through
/// the app's own framer.
class FakeTorControlChannel implements TorControlChannel {
  FakeTorControlChannel(this.tor) {
    tor._push = (lines) => scheduleMicrotask(() {
          for (final line in lines) {
            if (!_done.isCompleted) _framer.addLine(line);
          }
        });
    tor._hangUp = () => close();
  }

  final FakeTorControl tor;
  late final TorControlFramer _framer =
      TorControlFramer(onMessage: _onMessage);
  final _events = StreamController<TorControlReply>.broadcast();
  final _done = Completer<void>();
  Completer<TorControlReply>? _waiting;

  /// When set, the next command is never answered.
  bool silent = false;

  @override
  Stream<TorControlReply> get events => _events.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<TorControlReply> send(String command) async {
    if (_done.isCompleted) throw const TorControlClosed();
    if (silent) return Completer<TorControlReply>().future;
    final reply = Completer<TorControlReply>();
    _waiting = reply;
    for (final line in tor.answer(command)) {
      _framer.addLine(line);
    }
    return reply.future;
  }

  void _onMessage(TorControlReply message) {
    if (message.isEvent) {
      if (!_events.isClosed) _events.add(message);
      return;
    }
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete(message);
  }

  @override
  Future<void> close() async {
    if (_done.isCompleted) return;
    _done.complete();
    final waiting = _waiting;
    _waiting = null;
    waiting?.completeError(const TorControlClosed());
    await _events.close();
  }
}

Uint8List bytesOf(List<int> list) => Uint8List.fromList(list);
