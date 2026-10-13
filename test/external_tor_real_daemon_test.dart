// TOR-026 against a real tor: the control link and the whole external
// runtime, driven against tor processes configured the ways people run
// them: the Debian and Ubuntu tor service (a ControlSocket with its cookie),
// a ControlPort with a password, Tor Browser's (a ControlPort with its
// cookie), and one with no authentication.
//
// Every tor's only way out is a bridge on a loopback port nothing listens
// on, so nothing leaves the machine. Not DisableNetwork: under it tor opens
// no SOCKS listener, and the app rightly refuses a control port whose tor
// does not listen at the address sites use. Given
// WS_TOR_CONSENSUS_DIR (a cached-microdesc-consensus and cached-certs, as
// CollecTor publishes them) the tors load a real consensus, and exit
// countries are counted against real relays; without it a pin cannot be
// counted and goes in as the built-in tor's does.
//
// Needs `tor` on PATH. Skipped without it, except under WS_REAL_TOR=1,
// which CI sets after installing tor: there a missing tor fails rather
// than passing nothing.

@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/external_tor_posture_engine.dart';
import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_io.dart';
import 'package:webspace/services/tor_control_link.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_socks_probe_io.dart';
import 'package:webspace/services/tor_service.dart' show TorSiteHolder;

final String? _torBinary = _which('tor');
final bool _torRequired = Platform.environment['WS_REAL_TOR'] == '1';
final String? _consensusDir = Platform.environment['WS_TOR_CONSENSUS_DIR'];
const String _geoip = '/usr/share/tor/geoip';

String? _which(String name) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    final candidate = File('$dir/$name');
    if (dir.isNotEmpty && candidate.existsSync()) return candidate.path;
  }
  return null;
}

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// One tor process with a torrc of [lines] on top of the common ones.
class _Tor {
  _Tor._(this.dir, {required this.process, required this.socksPort});

  final Directory dir;
  final Process process;
  final int socksPort;
  final StringBuffer _output = StringBuffer();

  String get cookieFile => '${dir.path}/control.authcookie';
  String get controlSocket => '${dir.path}/control';

  static Future<_Tor> start(List<String> lines) async {
    final dir = await Directory.systemTemp.createTemp('wstor');
    final data = Directory('${dir.path}/data')..createSync();
    // tor makes a control socket only in a directory no one else can list.
    await Process.run('chmod', ['700', dir.path, data.path]);
    final consensus = _consensusDir;
    if (consensus != null) {
      for (final name in ['cached-microdesc-consensus', 'cached-certs']) {
        await File('$consensus/$name').copy('${data.path}/$name');
      }
    }
    final socksPort = await _freePort();
    final deadBridge = await _freePort();
    final torrc = File('${dir.path}/torrc')
      ..writeAsStringSync(
        [
          'DataDirectory ${data.path}',
          'SocksPort 127.0.0.1:$socksPort',
          'UseBridges 1',
          'Bridge 127.0.0.1:$deadBridge',
          if (File(_geoip).existsSync()) 'GeoIPFile $_geoip',
          'Log notice file ${dir.path}/log',
          ...lines.map((l) => l.replaceAll(r'$DIR', dir.path)),
        ].join('\n'),
      );
    final process = await Process.start(_torBinary!, ['-f', torrc.path]);
    final tor = _Tor._(dir, process: process, socksPort: socksPort);
    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen(tor._output.write);
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen(tor._output.write);
    addTearDown(tor.stop);
    return tor;
  }

  ({String host, int port}) get socks => (host: '127.0.0.1', port: socksPort);

  /// A channel to [endpoint], once tor has opened it. tor's own log is the
  /// failure when it never does.
  Future<TorControlChannel> open(TorControlEndpoint endpoint) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        return await openTorControl(endpoint);
      } on TorControlUnreachable catch (e) {
        if (DateTime.now().isAfter(deadline)) {
          final log = File('${dir.path}/log');
          fail(
            '$e\ntor printed:\n$_output\ntor log:\n'
            '${log.existsSync() ? log.readAsStringSync() : '(none)'}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// What a second controller (the user, nyx) reads and sets, signed in
  /// with tor's cookie or, given one, [password].
  Future<TorControlChannel> admin(
    TorControlEndpoint endpoint, {
    String? password,
  }) async {
    final channel = await open(endpoint);
    final auth = password == null
        ? hexOf(File(cookieFile).readAsBytesSync())
        : torQuoted(password);
    expect((await channel.send('AUTHENTICATE $auth')).isOk, isTrue);
    addTearDown(channel.close);
    return channel;
  }

  void reload() => process.kill(ProcessSignal.sighup);

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

Future<String?> _conf(TorControlChannel admin, {required String key}) async {
  final value = torKeyValues(await admin.send('GETCONF $key'))[key]?.single;
  return (value == null || value.isEmpty) ? null : value;
}

Future<TorControlAttach> _attach(
  _Tor tor, {
  required TorControlEndpoint endpoint,
  String? password,
}) async => TorControlLink.attach(
  channel: await tor.open(endpoint),
  password: password,
  readCookie: readTorCookie,
  socks: tor.socks,
);

/// The link, or a failure that says why tor would not give one.
TorControlLink _linked(TorControlAttach result) => switch (result) {
  TorControlLinked(:final link) => link,
  TorControlNotLinked(:final refusal, :final detail) => fail(
    'not linked: $refusal: $detail',
  ),
};

Future<T> _next<T extends TorControlLinkEvent>(TorControlLink link) => link
    .changes
    .where((e) => e is T)
    .cast<T>()
    .first
    .timeout(const Duration(seconds: 20));

void main() {
  if (_torBinary == null) {
    test('tor is on PATH', () {
      expect(
        _torRequired,
        isFalse,
        reason: 'WS_REAL_TOR=1 and no tor on PATH: install tor',
      );
    }, skip: _torRequired ? false : 'no tor on PATH');
    return;
  }

  group("the Debian and Ubuntu tor service's control socket", () {
    late _Tor tor;
    late TorControlEndpoint endpoint;

    setUp(() async {
      tor = await _Tor.start([
        r'ControlSocket $DIR/control',
        'CookieAuthentication 1',
        r'CookieAuthFile $DIR/control.authcookie',
      ]);
      endpoint = TorControlSocket(tor.controlSocket);
    });

    test('takes SAFECOOKIE and matches the built-in isolation', () async {
      final link = _linked(await _attach(tor, endpoint: endpoint));
      addTearDown(link.close);
      expect(link.version, startsWith('0.4'));
      expect(link.posture.gaps, isEmpty);
    });

    test("a cookie the app cannot read is named as such", () async {
      final result =
          await TorControlLink.attach(
                channel: await tor.open(endpoint),
                password: null,
                readCookie: (_) async => null,
                socks: tor.socks,
              )
              as TorControlNotLinked;
      expect(result.refusal, TorControlRefusal.cookieUnreadable);
    });

    test('lists what another controller changes', () async {
      final link = _linked(await _attach(tor, endpoint: endpoint));
      addTearDown(link.close);
      final admin = await tor.admin(endpoint);
      final changed = _next<TorLinkPostureChanged>(link);
      expect(
        (await admin.send(
          'SETCONF SocksPort="127.0.0.1:${tor.socksPort} '
          'IsolateDestAddr NoIsolateSOCKSAuth" SafeLogging=0 '
          'ExitNodes={us}',
        )).isOk,
        isTrue,
      );
      final gaps = (await changed).posture.gaps;
      expect(gaps.map((g) => g.runtimeType).toSet(), {
        TorSharedCircuits,
        TorPerDestinationHost,
        TorOwnExits,
        TorLogsAddresses,
      });
      expect(gaps.whereType<TorOwnExits>().single.nodes, '{us}');
    });

    test('a control socket whose tor is not at the SOCKS address is not '
        'used', () async {
      final result =
          await TorControlLink.attach(
                channel: await tor.open(endpoint),
                password: null,
                readCookie: readTorCookie,
                socks: (host: '127.0.0.1', port: tor.socksPort + 1),
              )
              as TorControlNotLinked;
      expect(result.refusal, TorControlRefusal.otherTor);
    });

    test('NEWNYM is accepted', () async {
      final link = _linked(await _attach(tor, endpoint: endpoint));
      addTearDown(link.close);
      await link.newCircuits();
    });

    test('pins an exit country and puts the tor back as it was', () async {
      final admin = await tor.admin(endpoint);
      final link = _linked(await _attach(tor, endpoint: endpoint));
      await link.pin('{de}');
      expect(await _conf(admin, key: 'ExitNodes'), '{de}');
      expect(await _conf(admin, key: 'StrictNodes'), '1');
      expect(await _conf(admin, key: 'ConfluxEnabled'), '0');

      await link.pin(null);
      expect(await _conf(admin, key: 'ExitNodes'), isNull);
      expect(await _conf(admin, key: 'StrictNodes'), '0');
      expect(await _conf(admin, key: 'ConfluxEnabled'), 'auto');

      await link.pin('{nl}');
      await link.close();
      expect(
        await _conf(admin, key: 'ExitNodes'),
        isNull,
        reason: 'letting the link go gives the tor back its own exits',
      );
    });

    test("the tor's own exits come back, not none", () async {
      final admin = await tor.admin(endpoint);
      expect((await admin.send('SETCONF ExitNodes={ca}')).isOk, isTrue);
      final link = _linked(await _attach(tor, endpoint: endpoint));
      await link.pin('{de}');
      await link.close();
      expect(await _conf(admin, key: 'ExitNodes'), '{ca}');
    });

    test(
      'a country with no exit in the consensus is refused',
      () async {
        final admin = await tor.admin(endpoint);
        final link = _linked(await _attach(tor, endpoint: endpoint));
        addTearDown(link.close);
        await expectLater(
          link.pin('{aq}'),
          throwsA(isA<TorExitCountryEmpty>()),
        );
        expect(await _conf(admin, key: 'ExitNodes'), isNull);
      },
      skip: _consensusDir == null ? 'needs WS_TOR_CONSENSUS_DIR' : false,
    );

    test('a reload under a pin loses the link', () async {
      final link = _linked(await _attach(tor, endpoint: endpoint));
      addTearDown(link.close);
      await link.pin('{de}');
      final lost = _next<TorLinkLost>(link);
      tor.reload();
      expect((await lost).reason, contains('exit configuration'));
    });

    test('tor exiting loses the link', () async {
      final link = _linked(await _attach(tor, endpoint: endpoint));
      addTearDown(link.close);
      final lost = _next<TorLinkLost>(link);
      tor.process.kill();
      await lost;
    });
  });

  group('a ControlPort with a password', () {
    late _Tor tor;
    late TorControlEndpoint endpoint;

    setUp(() async {
      final hash = (await Process.run(_torBinary!, [
        '--quiet',
        '--hash-password',
        'hunter2',
      ])).stdout.toString().trim().split('\n').last;
      final port = await _freePort();
      tor = await _Tor.start([
        'ControlPort 127.0.0.1:$port',
        'HashedControlPassword $hash',
      ]);
      endpoint = TorControlTcp('127.0.0.1', port: port);
    });

    test('needs it, refuses a wrong one, takes the right one', () async {
      expect(
        ((await _attach(tor, endpoint: endpoint)) as TorControlNotLinked)
            .refusal,
        TorControlRefusal.needsPassword,
      );
      expect(
        ((await _attach(tor, endpoint: endpoint, password: 'wrong'))
                as TorControlNotLinked)
            .refusal,
        TorControlRefusal.refused,
      );
      final link = _linked(
        await _attach(tor, endpoint: endpoint, password: 'hunter2'),
      );
      await link.close();
    });
  });

  test("Tor Browser's: a ControlPort with its cookie", () async {
    final port = await _freePort();
    final tor = await _Tor.start([
      'ControlPort 127.0.0.1:$port',
      'CookieAuthentication 1',
    ]);
    final result = await _attach(
      tor,
      endpoint: TorControlTcp('127.0.0.1', port: port),
    );
    await _linked(result).close();
  });

  test('a ControlPort with no authentication', () async {
    final port = await _freePort();
    final tor = await _Tor.start(['ControlPort 127.0.0.1:$port']);
    final result = await _attach(
      tor,
      endpoint: TorControlTcp('127.0.0.1', port: port),
    );
    await _linked(result).close();
  });

  test('the whole runtime: up, a pin, a reload, the pin again', () async {
    final tor = await _Tor.start([
      r'ControlSocket $DIR/control',
      'CookieAuthentication 1',
      r'CookieAuthFile $DIR/control.authcookie',
    ]);
    final endpoint = TorControlSocket(tor.controlSocket);
    final admin = await tor.admin(endpoint);
    final runtime = ExternalTorRuntime(
      address: () => '127.0.0.1:${tor.socksPort}',
      identify: identifyTor,
      control: ExternalTorControlAccess(
        endpoint: () => 'unix:${tor.controlSocket}',
        password: () async => null,
        connect: openTorControl,
        readCookie: readTorCookie,
      ),
    );
    final engine = TorEngine(
      runtime: runtime,
      sessionSecret: 'secret',
      socksProbe: torSocksAnswers,
    );
    addTearDown(engine.dispose);
    addTearDown(runtime.stop);
    Future<TorStatus> settled(Future<void> Function() action) {
      final next = engine.statusStream
          .firstWhere((s) => s is TorUp || s is TorErrored)
          .timeout(const Duration(seconds: 30));
      return action().then((_) => next);
    }

    final up = await settled(() => engine.acquire(TorSiteHolder('mail')));
    expect(up, isA<TorUp>(), reason: '$up');
    expect(runtime.controlState, isA<TorControlAttached>());

    expect(await settled(() => engine.setExitCountry('{de}')), isA<TorUp>());
    expect(await _conf(admin, key: 'ExitNodes'), '{de}');

    final held = engine.statusStream.firstWhere((s) => s is TorStarting);
    final back = engine.statusStream
        .firstWhere((s) => s is TorUp)
        .timeout(const Duration(seconds: 30));
    tor.reload();
    await held.timeout(const Duration(seconds: 20));
    expect(await back, isA<TorUp>());
    expect(
      await _conf(admin, key: 'ExitNodes'),
      '{de}',
      reason: 'the reload dropped it; the runtime put it back',
    );

    await engine.setExitCountry(null);
    expect(await _conf(admin, key: 'ExitNodes'), isNull);
  });
}
