// TOR-027 against a real tor: the Linux runtime starting the tor on this
// machine as the app would, driving it over its control socket, and
// stopping it. The tier TOR-021 asks for, on the platform whose runtime is
// Dart: managed_tor_runtime_test.dart drives the same code against a fake.
//
// tor's only way out is a bridge on a loopback port nothing listens on, so
// nothing leaves the machine and bootstrap stays early; WEBSPACE_TOR_NETWORK=1
// takes the bridge away and asks for `up` on the real Tor network as well.
// The bridge case runs a bridge of its own on loopback, which asks nothing of
// the Tor network either.
//
// Needs `tor` on PATH or in /usr/sbin. Skipped without it, except under
// WS_REAL_TOR=1, which CI sets after installing tor and obfs4proxy or
// lyrebird: there a missing tor, transport or bridge fails rather than
// passing nothing. With WS_TOR_BESIDE naming a built bundle's executable, the
// tor and lyrebird are the ones the build put beside it (linux/tor.cmake), as
// the app finds them.

@Timeout(Duration(seconds: 240))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/managed_tor_io.dart';
import 'package:webspace/services/managed_tor_runtime.dart';
import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_io.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_socks_probe_io.dart';

final bool _required = Platform.environment['WS_REAL_TOR'] == '1';
final bool _network = Platform.environment['WEBSPACE_TOR_NETWORK'] == '1';

final String? _beside = Platform.environment['WS_TOR_BESIDE'];

/// The tor the app would run: beside [_beside], or where the build bundles
/// none, the one this machine has.
final ManagedTorInstall? _install = findManagedTor(
  executable:
      _beside == null ? Platform.resolvedExecutable : File(_beside!).absolute.path,
  environment: Platform.environment,
);

/// [name] where a distribution installs it: on PATH or in an sbin
/// directory.
String? _onMachine(String name) {
  final dirs = [
    ...(Platform.environment['PATH'] ?? '').split(':').where((d) => d.isNotEmpty),
    '/usr/local/sbin', '/usr/sbin', '/sbin',
  ];
  for (final dir in dirs) {
    if (File('$dir/$name').existsSync()) return '$dir/$name';
  }
  return null;
}

/// An obfs4 bridge on loopback: a relay-capable [tor] serving obfs4 through
/// [server], whose only directory authority is a dead loopback port, so it
/// never reaches the Tor network and a client gets no further than the
/// bridge's own directory.
final class _Bridge {
  _Bridge._({required this.process, required this.data, required this.line});

  final Process process;
  final Directory data;

  /// Its line as a user pastes one.
  final String line;

  static const _zero = '0000000000000000000000000000000000000000';

  static Future<_Bridge> start({
    required String tor,
    required String server,
  }) async {
    final data = await Directory.systemTemp.createTemp('wsbridge');
    final torrc = File('${data.path}/torrc')..writeAsStringSync('');
    // Each named, never `auto`: tor took a port the test had released for
    // obfs4 as its own ExtORPort, and tor refuses port 0 for a transport.
    final [orPort, extOrPort, obfs4] = await _freePorts(count: 3);
    final process = await Process.start(tor, [
      '-f', torrc.path, '--defaults-torrc', torrc.path,
      '--DataDirectory', '${data.path}/tor',
      '--SocksPort', '0',
      '--ORPort', '127.0.0.1:$orPort',
      '--ExtORPort', '127.0.0.1:$extOrPort',
      '--BridgeRelay', '1',
      '--PublishServerDescriptor', '0',
      '--AssumeReachable', '1',
      '--ExitRelay', '0',
      '--DirAuthority', 'none orport=1 no-v2 v3ident=$_zero 127.0.0.1:1 $_zero',
      '--ServerTransportPlugin', 'obfs4 exec $server',
      '--ServerTransportListenAddr', 'obfs4 127.0.0.1:$obfs4',
      '--Log', 'notice stdout',
    ]);
    final said = <String>[];
    final registered = Completer<void>();
    process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      said.add(line);
      if (line.contains("Registered server transport 'obfs4' at '127.0.0.1:$obfs4'") &&
          !registered.isCompleted) {
        registered.complete();
      }
    });
    process.stderr.drain<void>().ignore();
    await registered.future.timeout(const Duration(seconds: 60), onTimeout: () {
      process.kill();
      fail('the bridge registered no obfs4 transport; it said:\n${said.join('\n')}');
    });
    final fingerprint =
        File('${data.path}/tor/fingerprint').readAsStringSync().trim().split(' ').last;
    final cert = RegExp(r'cert=(\S+)')
        .firstMatch(File('${data.path}/tor/pt_state/obfs4_bridgeline.txt').readAsStringSync())
        ?.group(1);
    if (cert == null) fail('$server wrote no obfs4 cert');
    return _Bridge._(
      process: process,
      data: data,
      line: 'obfs4 127.0.0.1:$obfs4 $fingerprint cert=$cert iat-mode=0',
    );
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode;
    await data.delete(recursive: true);
  }
}

Future<int> _deadPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// [count] loopback ports, all bound at once before any is released, so no
/// two are the same.
Future<List<int>> _freePorts({required int count}) async {
  final held = [
    for (var i = 0; i < count; i++)
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  ];
  final ports = [for (final socket in held) socket.port];
  for (final socket in held) {
    await socket.close();
  }
  return ports;
}

/// The first status [runtime] publishes that [matches], or a failure
/// carrying tor's log when none comes within [within].
Future<T> _until<T extends TorStatus>(
  ManagedTorRuntime runtime, {
  required Duration within,
  bool Function(T status)? matches,
}) =>
    runtime.events
        .where((s) => s is T && (matches?.call(s) ?? true))
        .cast<T>()
        .first
        .timeout(within, onTimeout: () {
      final log = LogService.instance.recent(
          {LogTag.tor, LogTag.torLog},
          limit: 40, scan: 4000);
      fail('no $T within $within; tor and the runtime said:\n'
          '${log.map((e) => '  [${e.tag}] ${e.message}').join('\n')}');
    });

void main() {
  final install = _install;
  if (install == null) {
    test('TOR-027 a tor is on this machine', () {
      if (_required) fail('WS_REAL_TOR=1, and no tor is on PATH or in sbin');
      markTestSkipped('no tor on PATH or in sbin');
    });
    return;
  }

  if (_beside != null) {
    test('TOR-027 the build bundles its tor and the lyrebird that runs its '
        'transports', () {
      expect(install.bundled, isTrue, reason: 'tor beside $_beside');
      final lyrebird =
          '${File(install.tor).parent.path}/pluggable_transports/lyrebird';
      for (final transport in TorTransport.values) {
        expect(install.transports[transport]?.firstOrNull,
            transport == TorTransport.dnstt ? isNull : lyrebird,
            reason: '$transport runs the bundled lyrebird first');
      }
    });
  }

  late Directory cache;
  late ManagedTorRuntime runtime;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('wstorcache');
    LogService.instance.resetForTest();
    runtime = ManagedTorRuntime(
      install: install,
      host: IoManagedTorHost(cacheRoot: cache),
    );
    if (!_network) {
      await runtime.setTorrcOptions([
        ('UseBridges', '1'),
        ('Bridge', '127.0.0.1:${await _deadPort()}'),
      ]);
    }
  });

  tearDown(() async {
    await runtime.stop();
    await cache.delete(recursive: true);
  });

  test('TOR-027 the real tor: its control socket, its phase, its log, a '
      'stop it obeys, and a start after it', () async {
    final phase = _until<TorBootstrapping>(runtime,
        within: const Duration(seconds: 60), matches: (s) => s.tag != null);
    await runtime.start();
    final first = await phase;
    expect(first.tag, isNotEmpty, reason: "tor's own phase (TOR-018)");

    expect(
        LogService.instance.sensitiveEntries
            .where((e) => e.tag == LogTag.torLog.label),
        isNotEmpty,
        reason: "tor's own log reaches the app log under its own tag");
    expect(
        LogService.instance.entries.map((e) => e.message),
        contains('Control port authenticated.'));

    if (_network) {
      final up = await _until<TorUp>(runtime,
          within: const Duration(seconds: 150));
      expect(await torSocksAnswers(up.host, port: up.port), isTrue);
      expect(await runtime.circuitEstablished(), isTrue);
    }

    final kept = Directory(cache.path)
        .listSync()
        .whereType<Directory>()
        .any((d) => d.path.endsWith('/tor'));
    expect(kept, isTrue, reason: 'tor keeps its state in the app cache');

    await runtime.stop();
    // Nothing answers where it listened: it exited, not only went quiet.
    final log = LogService.instance.entries.map((e) => e.message).toList();
    expect(log, contains('Stopping tor.'));

    final again = _until<TorBootstrapping>(runtime,
        within: const Duration(seconds: 60));
    await runtime.start();
    await again;
  });

  test('TOR-027 a configuration tor rejects fails with what tor said',
      () async {
    await runtime.setTorrcOptions(const [('Bridgee', '127.0.0.1:1')]);
    final failed = _until<TorErrored>(runtime,
        within: const Duration(seconds: 60));
    await runtime.start();
    final failure = await failed;
    expect(failure.message, contains('exited before it connected'));
    expect(failure.message, contains('Bridgee'),
        reason: "tor's own reason, not a timeout");
  });

  test('TOR-027 an exit pin and a reopen go through on the real control '
      'port', () async {
    final attached = _until<TorBootstrapping>(runtime,
        within: const Duration(seconds: 60));
    await runtime.start();
    await attached;

    // A one-row table in tor's format: enough for tor to report GeoIP
    // loaded, which is all a pin waits for before its SETCONF.
    final geoip = File('${cache.path}/geoip-test')
      ..writeAsStringSync('16777216,16777471,DE\n');
    await runtime.applyExitCountry('{de}', geoipFile: geoip.path);
    await runtime.applyExitCountry(null);

    final reopened = _until<TorUp>(runtime, within: const Duration(seconds: 30));
    await runtime.reopenListeners(bridgeOptions: const []);
    final up = await reopened;
    expect(await torSocksAnswers(up.host, port: up.port), isTrue,
        reason: 'the listener tor opened after DisableNetwork answers');
  });

  final obfs4 = install.transports[TorTransport.obfs4] ?? const [];
  test('TOR-027 a pluggable transport on this machine names its listener',
      () async {
    if (obfs4.isEmpty) {
      if (_required) fail('WS_REAL_TOR=1, and no lyrebird or obfs4proxy here');
      markTestSkipped('no lyrebird or obfs4proxy here');
      return;
    }
    final port = await runtime.startTransport('obfs4');
    expect(port, greaterThan(0));
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.destroy();
    expect(await runtime.restartTransport('obfs4'), greaterThan(0));
  });

  // The bridge is the machine's: the bundle's tor is a client alone. Past 25%
  // the client has made its TLS handshake with the bridge through obfs4 and a
  // one-hop circuit to it, and asked it for the consensus it cannot have.
  test('TOR-016 tor reaches an obfs4 bridge through its transport', () async {
    final relay = _onMachine('tor');
    final server = _onMachine('lyrebird') ?? _onMachine('obfs4proxy');
    final modules = relay == null
        ? ''
        : (await Process.run(relay, ['--list-modules'])).stdout as String;
    if (obfs4.isEmpty || server == null || !modules.contains('relay: yes')) {
      if (_required) {
        fail('WS_REAL_TOR=1, and no obfs4 client, relay-capable tor and obfs4 '
            'server here to bridge with');
      }
      markTestSkipped('no obfs4 client, relay-capable tor and obfs4 server here');
      return;
    }
    final bridge = await _Bridge.start(tor: relay!, server: server);
    addTearDown(bridge.stop);
    final line = parseTorBridgeLine(bridge.line).line;
    expect(line, isNotNull, reason: bridge.line);

    final port = await runtime.startTransport('obfs4');
    expect(port, greaterThan(0));
    await runtime.setTorrcOptions(torBridgeOptions(
      TorBridgeConfig(enabled: true, transport: TorTransport.obfs4, lines: [line!]),
      transportPort: port,
    ));
    final through = _until<TorBootstrapping>(runtime,
        within: const Duration(seconds: 90), matches: (s) => s.percent >= 25);
    await runtime.start();
    final reached = await through;
    expect(reached.tag, isNotNull, reason: '$reached');
  });

  test('TOR-027 the control socket is private to this user', () async {
    final attached = _until<TorBootstrapping>(runtime,
        within: const Duration(seconds: 60));
    await runtime.start();
    await attached;
    final sockets = Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('/wstor') && File('${d.path}/torrc').existsSync());
    expect(sockets, isNotEmpty);
    for (final dir in sockets) {
      final mode = dir.statSync().mode & 0x1ff;
      expect(mode, 0x1c0, reason: '${dir.path} is 0700');
    }
    // And it answers as tor's control port does, to PROTOCOLINFO only.
    final socket = sockets.first;
    final channel =
        await openTorControl(TorControlSocket('${socket.path}/control'));
    final info = TorProtocolInfo.fromReply(await channel.send('PROTOCOLINFO 1'));
    expect(info?.methods, contains(TorAuthMethod.safeCookie));
    await channel.close();
  });
}
