// The built-in Tor on Linux (TOR-027): a tor the app starts as a child
// process and drives over its control socket. Driven here against a fake
// machine whose tor is FakeTorControl, the control protocol the external
// tor's link is tested against too; managed_tor_real_test.dart runs a real
// one.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/managed_tor_io.dart';
import 'package:webspace/services/managed_tor_runtime.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_holders.dart';
import 'package:webspace/services/tor_log.dart';
import 'package:webspace/services/tor_service.dart' show builtInTorOffered;
import 'package:webspace/settings/app_prefs.dart';

import 'helpers/fake_managed_tor_host.dart';

const _install = ManagedTorInstall(
  tor: '/app/lib/tor/tor',
  environment: {'LD_LIBRARY_PATH': '/app/lib/tor'},
  transports: {
    TorTransport.obfs4: ['/app/lib/tor/pluggable_transports/lyrebird'],
    TorTransport.snowflake: [
      '/app/lib/tor/pluggable_transports/lyrebird',
      '/usr/bin/snowflake-client',
    ],
    TorTransport.meekLite: [],
    TorTransport.webtunnel: [],
    TorTransport.dnstt: [],
  },
  bundled: true,
);

/// Statuses [runtime] publishes from here on.
List<TorStatus> _recording(ManagedTorRuntime runtime) {
  final out = <TorStatus>[];
  runtime.events.listen(out.add);
  return out;
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The value after [flag] in [arguments].
String? _arg(List<String> arguments, {required String flag}) {
  final at = arguments.indexOf(flag);
  return at < 0 || at + 1 >= arguments.length ? null : arguments[at + 1];
}

void main() {
  late FakeManagedTorHost host;
  late ManagedTorRuntime runtime;

  setUp(() {
    host = FakeManagedTorHost();
    runtime = ManagedTorRuntime(install: _install, host: host);
  });

  group('TOR-027 launch', () {
    test('runs tor with nothing from a torrc of the machine, a private '
        'control socket, and the app as its owner', () async {
      await runtime.setTorrcOptions(const [
        ('UseBridges', '1'),
        ('Bridge', 'obfs4 192.0.2.1:443 AAAA cert=x iat-mode=0'),
        ('Bridge', 'obfs4 192.0.2.2:443 BBBB cert=y iat-mode=0'),
      ]);
      await runtime.start();
      final launch = host.torProcess!.launch;
      final args = launch.arguments;
      final places = host.prepared.single;

      expect(launch.executable, '/app/lib/tor/tor');
      expect(launch.environment['LD_LIBRARY_PATH'], '/app/lib/tor');
      expect(_arg(args, flag: '-f'), places.torrc);
      expect(_arg(args, flag: '--defaults-torrc'), places.torrc);
      expect(_arg(args, flag: '--DataDirectory'), places.dataDirectory);
      expect(_arg(args, flag: '--ControlSocket'), places.controlSocket);
      expect(_arg(args, flag: '--CookieAuthentication'), '1');
      expect(_arg(args, flag: '--SocksPort'), 'auto IsolateSOCKSAuth',
          reason: 'never 9050, and isolation by credentials (TOR-003)');
      expect(_arg(args, flag: '--ConfluxEnabled'), '0');
      expect(_arg(args, flag: '--SafeLogging'), '1');
      expect(_arg(args, flag: '--__OwningControllerProcess'), '4242',
          reason: 'tor exits with the app, however it ends');
      expect(args.where((a) => a == '--Bridge'), hasLength(2),
          reason: 'a repeated key stays repeated');
    });

    test('attaches once the socket answers, takes ownership, and publishes '
        'the bootstrap as tor reports it', () async {
      host.refusedConnects = 3;
      final seen = _recording(runtime);
      await runtime.start();
      await _settle();
      await Future<void>.delayed(kManagedTorAttachPoll * 4);
      await _settle();
      expect(host.connects, 4);
      expect(host.tor.owned, isTrue,
          reason: 'tor exits when the app lets its control channel go');
      expect(host.tor.commands, contains('SETEVENTS STATUS_CLIENT'));

      host.tor.bootstrap(5, tag: 'conn', summary: 'Connecting to a relay');
      await _settle();
      host.tor.bootstrap(100, tag: 'done', summary: 'Done');
      await _settle();

      expect(seen.first, isA<TorStarting>());
      final phases = seen.whereType<TorBootstrapping>().toList();
      expect(phases.map((s) => s.percent), [0, 5, 100]);
      expect(phases[1].tag, 'conn');
      expect(phases[1].summary, 'Connecting to a relay');
      expect(seen.last, isA<TorUp>());
      final up = seen.last as TorUp;
      expect('${up.host}:${up.port}', '127.0.0.1:41337');
    });

    test('CIRCUIT_ESTABLISHED is done too, and a later phase does not walk '
        'it back', () async {
      final seen = _recording(runtime);
      await runtime.start();
      await _settle();
      host.tor.bootstrap(90, tag: 'ap_handshake_done');
      await _settle();
      host.tor.establishCircuit();
      await _settle();
      host.tor.bootstrap(95, tag: 'circuit_create');
      await _settle();
      expect(seen.last, isA<TorUp>());
    });

    test('a tor already done when the control port attaches is up at once',
        () async {
      host.tor.bootstrapPhase =
          'NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done"';
      final seen = _recording(runtime);
      await runtime.start();
      await _settle();
      expect(seen.last, isA<TorUp>());
    });

    test("a tor that exits before connecting fails with tor's own reason, "
        'and a start after it launches another', () async {
      host.listening = false;
      final seen = _recording(runtime);
      await runtime.start();
      host.torProcess!
        ..say('Oct 30 10:56:07.000 [warn] Failed to parse/validate config: '
            "Unknown option 'Bridgee'.")
        ..say('Oct 30 10:56:07.000 [err] Reading config failed--see warnings '
            'above.');
      await _settle();
      host.torProcess!.exit(1);
      await _settle();

      final failure = seen.last as TorErrored;
      expect(failure.message, contains('exited before it connected (code 1)'));
      expect(failure.message, contains("Unknown option 'Bridgee'"));
      expect(host.released, contains(host.prepared.single),
          reason: 'the launch leaves no directory behind');

      // A child process leaves nothing behind in this one, so a Retry gets
      // a fresh tor rather than the session-long refusal Apple's needs.
      host.listening = true;
      await runtime.start();
      await _settle();
      expect(host.launches.where((c) => c.launch.executable == _install.tor),
          hasLength(2));
      expect(seen.last, isA<TorBootstrapping>());
    });

    test('a start while tor runs launches nothing (TOR-020)', () async {
      await runtime.start();
      await _settle();
      await runtime.start();
      await runtime.start();
      expect(host.launches, hasLength(1));
    });

    test('tor exiting once up is a failure that says so', () async {
      final seen = _recording(runtime);
      await runtime.start();
      await _settle();
      host.tor.bootstrap(100, tag: 'done');
      await _settle();
      host.torProcess!.exit(0);
      await _settle();
      expect((seen.last as TorErrored).message, contains('Tor exited (code 0)'));
    });

    test("tor's log reaches the app log as tor's, and the runtime's notes "
        'as its own (TOR-018)', () async {
      LogService.instance.resetForTest();
      await runtime.start();
      host.torProcess!.say(
          'Oct 30 10:56:07.829 [notice] Opening Socks listener on 127.0.0.1:0');
      await _settle();
      expect(
          LogService.instance.sensitiveEntries.where((e) =>
              e.tag == LogTag.torLog.label &&
              e.message == 'Opening Socks listener on 127.0.0.1:0'),
          hasLength(1),
          reason: 'a relay or bridge tor names is kept out of the shared log');
      expect(
          LogService.instance.entries.where((e) =>
              e.tag == LogTag.tor.label && e.message.startsWith('Starting the bundled tor')),
          isNotEmpty);
    });
  });

  group('TOR-027 a tor nobody can talk to is retired (TOR-020)', () {
    test('control port never answering', () {
      fakeAsync((async) {
        host.listening = false;
        final seen = _recording(runtime);
        unawaited(runtime.start());
        async.elapse(kManagedTorAttachPoll * (kManagedTorAttachAttempts + 2));
        final failure = seen.last as TorErrored;
        expect(failure.kind, TorFailureKind.controlChannel);
        expect(host.torProcess!.kills, [false],
            reason: 'the tor is stopped, so a Retry starts one that answers');
        async.flushMicrotasks();
        expect(seen.last, same(failure),
            reason: 'its exit does not overwrite why it was retired');
      });
    });

    test('authentication refused', () async {
      host.tor.methods
        ..clear()
        ..add(TorAuthMethod.hashedPassword);
      final seen = _recording(runtime);
      await runtime.start();
      await _settle();
      final failure = seen.last as TorErrored;
      expect(failure.message, contains('Tor control authentication failed'));
      expect(failure.kind, TorFailureKind.controlChannel);
      expect(host.torProcess!.exited, isTrue);
    });
  });

  group('TOR-027 stop', () {
    test('asks tor to halt over its own channel and waits for it', () async {
      final seen = _recording(runtime);
      await runtime.start();
      await _settle();
      await runtime.stop();
      await _settle();
      expect(host.tor.halted, isTrue);
      expect(host.torProcess!.exited, isTrue);
      expect(host.torProcess!.kills, isEmpty);
      expect(seen.last, isA<TorStopped>());
      expect(seen.whereType<TorErrored>(), isEmpty,
          reason: 'an exit asked for is not a failure');
    });

    test('a tor with no control channel yet is sent SIGTERM at once, and '
        'SIGKILL when it ignores it', () {
      fakeAsync((async) {
        host.listening = false;
        unawaited(runtime.start());
        async.flushMicrotasks();
        final tor = host.torProcess!..diesOnTerm = false;
        var stopped = false;
        unawaited(runtime.stop().then((_) => stopped = true));
        async.flushMicrotasks();
        expect(tor.kills, [false]);
        async.elapse(kManagedTorExitWait * 2);
        expect(tor.kills, [false, true]);
        expect(stopped, isTrue);
      });
    });

    test('a tor that took HALT and does not exit gets SIGTERM, then SIGKILL',
        () {
      fakeAsync((async) {
        unawaited(runtime.start());
        async.flushMicrotasks();
        final tor = host.torProcess!..diesOnTerm = false;
        host.tor.onHalt = null;
        unawaited(runtime.stop());
        async.flushMicrotasks();
        expect(host.tor.halted, isTrue);
        expect(tor.kills, isEmpty, reason: 'it was asked; it gets its wait');
        async.elapse(kManagedTorExitWait * 3);
        expect(tor.kills, [false, true]);
      });
    });
  });

  group('TOR-027 commands on a tor that is up', () {
    Future<void> up() async {
      await runtime.start();
      await _settle();
      host.tor.bootstrap(100, tag: 'done');
      await _settle();
    }

    test('an exit pin loads the GeoIP table first, counts the exits, pins '
        'strictly, and closes the circuits from before (TOR-014)', () async {
      host.tor.relays = [('192.0.2.10', 'de'), ('192.0.2.11', 'fr')];
      host.tor.circuits = [
        '7 BUILT \$AAAA,\$BBBB,\$CCCC PURPOSE=GENERAL',
        '8 BUILT \$DDDD PURPOSE=HS_CLIENT_INTRO',
      ];
      await up();
      await runtime.applyExitCountry('{de}',
          geoipFile: '/cache/tor_geoip/geoip-20261030');
      final commands = host.tor.commands;
      final geoip =
          commands.indexOf('SETCONF GeoIPFile="/cache/tor_geoip/geoip-20261030"');
      final pin = commands
          .indexOf('SETCONF ExitNodes="{de}" StrictNodes=1 ConfluxEnabled=0');
      expect(geoip, greaterThanOrEqualTo(0));
      expect(pin, greaterThan(geoip));
      expect(host.tor.closedCircuits, ['7']);

      await runtime.applyExitCountry(null);
      expect(host.tor.commands, contains('RESETCONF ExitNodes'));
      expect(host.tor.commands,
          contains('SETCONF StrictNodes=0 ConfluxEnabled=0'));
    });

    test('a country with no exit is refused before tor sees it', () async {
      host.tor.relays = [('192.0.2.10', 'de')];
      await up();
      await expectLater(runtime.applyExitCountry('{is}', geoipFile: '/g'),
          throwsA(isA<TorExitCountryEmpty>()));
      expect(host.tor.commands.where((c) => c.startsWith('SETCONF ExitNodes')),
          isEmpty);
    });

    test('a pin tor cannot resolve is refused as missing GeoIP data',
        () async {
      host.tor.geoip = false;
      await up();
      try {
        await runtime.applyExitCountry('{de}', geoipFile: '/g');
        fail('the pin went in without GeoIP');
      } on TorRuntimeFailure catch (e) {
        expect(classifyTorFailure(e.message).kind,
            TorFailureKind.exitCountryData);
      }
    });

    test('new circuits, a circuit asked for, and a reopen', () async {
      await up();
      await runtime.rebuildCircuits();
      expect(host.tor.newnyms, 1);

      expect(await runtime.circuitEstablished(), isFalse);
      host.tor.circuitEstablished = true;
      expect(await runtime.circuitEstablished(), isTrue);

      final seen = _recording(runtime);
      host.tor.socksListeners = ['127.0.0.1:41999'];
      await runtime.reopenListeners(bridgeOptions: const [
        ('ClientTransportPlugin', 'obfs4 socks5 127.0.0.1:5000'),
      ]);
      await _settle();
      final commands = host.tor.commands;
      final off = commands.indexOf('SETCONF DisableNetwork=1');
      final on = commands.indexOf('SETCONF ClientTransportPlugin="obfs4 '
          'socks5 127.0.0.1:5000" DisableNetwork=0');
      expect(off, greaterThanOrEqualTo(0));
      expect(on, greaterThan(off));
      expect((seen.last as TorUp).port, 41999);
    });

    test('a command before tor is up is refused, not sent', () async {
      await expectLater(runtime.circuitEstablished(),
          throwsA(isA<TorRuntimeFailure>()));
    });
  });

  group('TOR-027 pluggable transports', () {
    test('a transport runs under the managed-transport protocol and its '
        'port is answered, once', () async {
      expect(await runtime.startTransport('obfs4'), 4711);
      expect(await runtime.startTransport('obfs4'), 4711);
      final pt = host.transports.single.launch;
      expect(pt.executable, '/app/lib/tor/pluggable_transports/lyrebird');
      expect(pt.environment, containsPair('TOR_PT_MANAGED_TRANSPORT_VER', '1'));
      expect(pt.environment, containsPair('TOR_PT_CLIENT_TRANSPORTS', 'obfs4'));
      expect(pt.environment,
          containsPair('TOR_PT_STATE_LOCATION', '/cache/tor_transports'));
      expect(pt.environment, containsPair('TOR_PT_EXIT_ON_STDIN_CLOSE', '1'));
      expect(pt.environment, containsPair('LD_LIBRARY_PATH', '/app/lib/tor'));
    });

    test('a program that refuses the transport is followed by the next',
        () async {
      var asked = 0;
      host.transportAnswer = (transport) => asked++ == 0
          ? ['VERSION 1', 'CMETHOD-ERROR $transport no such transport', 'CMETHODS DONE']
          : ['VERSION 1', 'CMETHOD $transport socks5 127.0.0.1:5151', 'CMETHODS DONE'];
      expect(await runtime.startTransport('snowflake'), 5151);
      expect(host.transports.map((c) => c.launch.executable), [
        '/app/lib/tor/pluggable_transports/lyrebird',
        '/usr/bin/snowflake-client',
      ]);
      expect(host.transports.first.kills, isNotEmpty,
          reason: 'the one that refused is not left running');
    });

    test('a transport nothing here runs answers 0, which starts tor without '
        'bridges', () async {
      expect(await runtime.startTransport('dnstt'), 0);
      expect(await runtime.startTransport('webtunnel'), 0);
      expect(host.transports, isEmpty);
    });

    test('a transport that died is started again on the next ask', () async {
      expect(await runtime.startTransport('obfs4'), 4711);
      host.transports.single.exit(2);
      await _settle();
      host.transportPort = 4713;
      expect(await runtime.startTransport('obfs4'), 4713);
      expect(host.transports, hasLength(2));
    });

    test('a restart comes back on a fresh listener', () async {
      expect(await runtime.startTransport('obfs4'), 4711);
      host.transportPort = 4712;
      expect(await runtime.restartTransport('obfs4'), 4712);
      expect(host.transports.first.exited, isTrue);
    });

    test('stop ends the transports with tor', () async {
      await runtime.startTransport('obfs4');
      await runtime.start();
      await _settle();
      await runtime.stop();
      expect(host.transports.single.exited, isTrue);
    });
  });

  test('TOR-027 the engine drives it end to end: bridges on the command '
      'line, up behind them', () async {
    final engine = TorEngine(
      runtime: runtime,
      sessionSecret: 'secret',
      bridgeLoader: () async => const TorBridgeConfig(
        enabled: true,
        transport: TorTransport.obfs4,
        lines: [
          TorBridgeLine(
            raw: 'obfs4 192.0.2.1:443 AAAA cert=x iat-mode=0',
            transport: TorTransport.obfs4,
          ),
        ],
      ),
    );
    addTearDown(engine.dispose);
    await engine.acquire(const TorAppWideHolder());
    await _settle();
    final args = host.torProcess!.launch.arguments;
    expect(_arg(args, flag: '--ClientTransportPlugin'),
        'obfs4 socks5 127.0.0.1:4711');
    host.tor.bootstrap(100, tag: 'done');
    await _settle();
    expect(engine.status, isA<TorUp>());
    final socks = engine.socksFor(TorTag.app)!;
    expect(socks.address, '127.0.0.1:41337');
  });

  group('parsers', () {
    test('a managed transport line', () {
      expect(PtLine.parse('CMETHOD obfs4 socks5 127.0.0.1:4711'),
          isA<PtListening>().having((l) => l.port, 'port', 4711));
      expect(PtLine.parse('CMETHOD-ERROR snowflake no such transport'),
          isA<PtRefused>().having((l) => l.message, 'message', 'no such transport'));
      expect(PtLine.parse('CMETHODS DONE'), isA<PtDone>());
      expect(PtLine.parse('ENV-ERROR no TOR_PT_STATE_LOCATION'), isA<PtFailed>());
      expect(PtLine.parse('VERSION 1'), isNull);
      expect(PtLine.parse('CMETHOD obfs4 socks4 127.0.0.1:1'), isNull);
      expect(PtLine.parse('CMETHOD obfs4 socks5 127.0.0.1:x'), isNull);
    });

    test("a bootstrap phase as tor words it", () {
      final phase = torBootstrapPhase('NOTICE BOOTSTRAP PROGRESS=45 '
          'TAG=loading_descriptors SUMMARY="Loading \\"relay\\" descriptors"');
      expect(phase?.percent, 45);
      expect(phase?.tag, 'loading_descriptors');
      expect(phase?.summary, 'Loading "relay" descriptors');
      expect(
          torBootstrapPhase('STATUS_CLIENT WARN BOOTSTRAP PROGRESS=10 '
                  'TAG=conn_done SUMMARY="Connected to a relay" '
                  'WARNING="Connection reset" REASON=CONNECTRESET')
              ?.percent,
          10);
      expect(torBootstrapPhase('STATUS_CLIENT NOTICE CIRCUIT_ESTABLISHED'),
          isNull);
      expect(torBootstrapPhase('NOTICE BOOTSTRAP SUMMARY="unterminated'),
          isNull);
    });

    test("one of tor's log lines", () {
      final line =
          parseTorLogLine('Oct 30 10:56:07.000 [warn] Problem bootstrapping.');
      expect(line.level, LogLevel.warning);
      expect(line.message, 'Problem bootstrapping.');
      expect(line.fromTor, isTrue);
      expect(parseTorLogLine('no brackets here').message, 'no brackets here');
    });
  });

  test('TOR-027 Linux offers the built-in Tor only with its experiment on, '
      'Apple always, no other platform (DEVTOOLS-011)', () {
    for (final platform in TargetPlatform.values) {
      for (final on in [false, true]) {
        expect(builtInTorOffered(platform: platform, linuxExperiment: on),
            switch (platform) {
              TargetPlatform.iOS || TargetPlatform.macOS => true,
              TargetPlatform.linux => on,
              TargetPlatform.android ||
              TargetPlatform.fuchsia ||
              TargetPlatform.windows =>
                false,
            },
            reason: '$platform, experiment ${on ? 'on' : 'off'}');
      }
    }
    expect(AppPref.experimentalLinuxTor.fallback, isFalse,
        reason: 'a new experiment starts off');
  });

  group('TOR-027 which tor runs', () {
    late Directory root;
    setUp(() async => root = await Directory.systemTemp.createTemp('wsfind'));
    tearDown(() => root.delete(recursive: true));

    File touch(String path) => File('${root.path}/$path')
      ..createSync(recursive: true);

    test("the bundle's tor and lyrebird, before any on the machine", () {
      touch('app/lib/tor/tor');
      touch('app/lib/tor/pluggable_transports/lyrebird');
      touch('bin/tor');
      touch('bin/snowflake-client');
      final install = findManagedTor(
        executable: '${root.path}/app/webspace_app',
        environment: {'PATH': '${root.path}/bin', 'LD_LIBRARY_PATH': '/opt/x'},
      )!;
      expect(install.bundled, isTrue);
      expect(install.tor, '${root.path}/app/lib/tor/tor');
      expect(install.environment['LD_LIBRARY_PATH'],
          '${root.path}/app/lib/tor:/opt/x');
      expect(install.transports[TorTransport.obfs4],
          ['${root.path}/app/lib/tor/pluggable_transports/lyrebird']);
      expect(install.transports[TorTransport.snowflake], [
        '${root.path}/app/lib/tor/pluggable_transports/lyrebird',
        '${root.path}/bin/snowflake-client',
      ]);
      expect(install.transports[TorTransport.dnstt], isEmpty);
    });

    test("the machine's tor where the build bundles none, as a flatpak or "
        'snap that ships its own does', () {
      touch('bin/tor');
      touch('bin/obfs4proxy');
      final install = findManagedTor(
        executable: '${root.path}/app/webspace_app',
        environment: {'PATH': '${root.path}/bin'},
      )!;
      expect(install.bundled, isFalse);
      expect(install.tor, '${root.path}/bin/tor');
      expect(install.environment, isEmpty);
      expect(install.transports[TorTransport.obfs4],
          ['${root.path}/bin/obfs4proxy']);
    });

    test('none at all', () {
      // /usr/sbin/tor may be installed on the machine running this test.
      if (File('/usr/sbin/tor').existsSync() ||
          File('/usr/local/sbin/tor').existsSync() ||
          File('/sbin/tor').existsSync()) {
        markTestSkipped('this machine has a tor in an sbin directory');
        return;
      }
      expect(
          findManagedTor(
            executable: '${root.path}/app/webspace_app',
            environment: {'PATH': '${root.path}/bin'},
          ),
          isNull);
    });
  });
}
