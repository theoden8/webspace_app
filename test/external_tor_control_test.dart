// TOR-026: an external tor whose control port the user named. The engine
// and runtime are the real ones; tor is the fake that keeps a configuration,
// over an in-memory channel or a real socket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/external_tor_posture_engine.dart';
import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_io.dart';
import 'package:webspace/services/tor_control_link.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_tor_control.dart';
import 'helpers/fake_tor_runtime.dart';

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeTorControl tor;
  late String endpoint;
  late ExternalTorRuntime runtime;
  late TorEngine engine;

  ExternalTorRuntime runtimeFor({required TorControlConnect connect}) =>
      ExternalTorRuntime(
        address: () => '127.0.0.1:9050',
        identify: (_, {required port}) async => ExternalTorAnswer.tor,
        control: ExternalTorControlAccess(
          endpoint: () => endpoint,
          password: () async => null,
          connect: connect,
          readCookie: (_) async => null,
        ),
      );

  setUp(() {
    tor = FakeTorControl(relays: [('2.2.2.2', 'de')]);
    endpoint = '/run/tor/control';
    runtime = runtimeFor(connect: (_) async => tor.connect());
    engine = TorEngine(
      runtime: runtime,
      sessionSecret: 'secret',
      socksProbe: (_, {required port}) async => true,
    );
  });

  tearDown(() => engine.dispose());

  Future<TorStatus> settled(Future<void> Function() action) {
    final next =
        engine.statusStream.firstWhere((s) => s is TorUp || s is TorErrored);
    return action().then((_) => next);
  }

  test('the control port is attached before Tor is reported up', () async {
    final states = <ExternalTorControlState>[];
    runtime.controlStates.listen(states.add);
    final s = await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    expect(s, isA<TorUp>());
    expect(states.map((s) => s.runtimeType),
        [TorControlAsking, TorControlAttached]);
    expect((runtime.controlState as TorControlAttached).gaps, isEmpty);
  });

  test('no control port named: as before, Tor up and no exit country',
      () async {
    endpoint = '';
    await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    expect(runtime.controlState, isA<TorControlIdle>());
    final pinned = await settled(() => engine.setExitCountry('{de}'));
    expect((pinned as TorErrored).kind, TorFailureKind.externalExitPin);
  });

  test('a control port that refuses leaves Tor up and says why', () async {
    tor = FakeTorControl(methods: {TorAuthMethod.hashedPassword}, password: 'p');
    final s = await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    expect(s, isA<TorUp>());
    expect((runtime.controlState as TorControlNotAttached).refusal,
        TorControlRefusal.needsPassword);
  });

  test('an exit country goes through the control port', () async {
    await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    final pinned = await settled(() => engine.setExitCountry('{de}'));
    expect(pinned, isA<TorUp>());
    expect(tor.config['ExitNodes'], ['{de}']);
    expect(engine.socksFor(TorTag.ofSite(SiteId('site-a'))), isNotNull);

    final cleared = await settled(() => engine.setExitCountry(null));
    expect(cleared, isA<TorUp>());
    expect(tor.config['ExitNodes'], isEmpty);
  });

  test('a reload that drops the pin holds the sites until it is back',
      () async {
    await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    await settled(() => engine.setExitCountry('{de}'));
    final seen = <TorStatus>[];
    engine.statusStream.listen(seen.add);

    tor.reload();
    await _settle();
    expect(seen.first, isA<TorStarting>(),
        reason: 'no site may use the tor while its pin is gone');
    expect(engine.status, isA<TorUp>());
    expect(tor.config['ExitNodes'], ['{de}']);
  });

  test('a control channel lost with no pin is opened again quietly',
      () async {
    await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    final seen = <TorStatus>[];
    engine.statusStream.listen(seen.add);
    tor.hangUp();
    await _settle();
    expect(seen, isEmpty, reason: 'nothing the sites rely on changed');
    expect(runtime.controlState, isA<TorControlAttached>());
  });

  test('NEWNYM reaches that tor', () async {
    await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    await engine.rebuildCircuits();
    expect(tor.newnyms, 1);
  });

  test('posture changes are published', () async {
    await settled(() => engine.acquire(TorSiteHolder(SiteId('site-a'))));
    final states = <ExternalTorControlState>[];
    runtime.controlStates.listen(states.add);
    tor.torrc['SocksPort'] = ['9050 NoIsolateSOCKSAuth'];
    tor.reload();
    await _settle();
    final attached = states.whereType<TorControlAttached>().last;
    expect(attached.gaps.single, isA<TorSharedCircuits>());
  });

  group('TorService', () {
    late FakeTorRuntime embeddedRuntime;
    late TorEngine embedded;
    late bool wantExternal;

    setUp(() {
      embeddedRuntime = FakeTorRuntime(
          onStart: (r) => r.emit(const TorUp('127.0.0.1', port: 39999)));
      embedded = TorEngine(runtime: embeddedRuntime, sessionSecret: 'e');
      wantExternal = true;
      TorService.wantsExternal = () => wantExternal;
      TorService.overrideEngines(
          embedded: embedded, external: engine, externalRuntime: runtime);
    });

    tearDown(TorService.reset);

    test('offers exit countries and new circuits once attached', () async {
      final service = TorService.instance;
      expect(service.hasControlPort, isFalse);
      await service.syncHolders({TorSiteHolder(SiteId('site-a'))});
      await _settle();
      expect(service.hasControlPort, isTrue);
      endpoint = '';
      await service.externalAddressChanged();
      await _settle();
      expect(service.hasControlPort, isFalse);
    });

    test("leaving the external tor gives it back its own exits", () async {
      final service = TorService.instance;
      await service.syncHolders({TorSiteHolder(SiteId('site-a'))});
      await service.setExitCountry('{de}');
      await _settle();
      expect(tor.config['ExitNodes'], ['{de}']);

      wantExternal = false;
      await service.runtimeChoiceChanged();
      await _settle();
      expect(tor.config['ExitNodes'], isEmpty);
      expect(embeddedRuntime.appliedExitNodes, ['{de}']);

      wantExternal = true;
      await service.runtimeChoiceChanged();
      await _settle();
      expect(tor.config['ExitNodes'], ['{de}'],
          reason: 'the pin is asked of the tor switched back to');
      expect(service.socksFor(siteId: SiteId('site-a')), isNotNull);
    });
  });

  group('over a socket', () {
    /// Serves [tor] as tor's control port does, line by line.
    void serve(ServerSocket server, {required FakeTorControl tor}) {
      server.listen((socket) {
        void write(List<String> lines) =>
            socket.write(lines.map((l) => '$l\r\n').join());
        tor.serveLines(push: write, hangUp: socket.destroy);
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) => write(tor.answer(line)));
      });
    }

    test('a Unix socket', () async {
      final dir = await Directory.systemTemp.createTemp('torctl');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/control';
      final server = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix), 0);
      addTearDown(server.close);
      serve(server, tor: tor);

      final channel = await openTorControl(TorControlSocket(path));
      final result = await TorControlLink.attach(
        channel: channel,
        password: null,
        readCookie: readTorCookie,
        socks: (host: '127.0.0.1', port: 9050),
      );
      final link = (result as TorControlLinked).link;
      final changes = <TorControlLinkEvent>[];
      link.changes.listen(changes.add);
      await link.pin('{de}');
      expect(tor.config['ExitNodes'], ['{de}']);

      tor.reload();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(changes.whereType<TorLinkLost>(), hasLength(1),
          reason: 'CONF_CHANGED arrives over the socket as an event');
      await link.close();
    });

    test('host:port, with the cookie read from disk', () async {
      final dir = await Directory.systemTemp.createTemp('torctl');
      addTearDown(() => dir.delete(recursive: true));
      final cookieTor = FakeTorControl(
        methods: {TorAuthMethod.cookie, TorAuthMethod.safeCookie},
        cookieFile: '${dir.path}/control_auth_cookie',
      );
      await File(cookieTor.cookieFile).writeAsBytes(cookieTor.cookie);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      serve(server, tor: cookieTor);

      final channel =
          await openTorControl(TorControlTcp('127.0.0.1', port: server.port));
      final result = await TorControlLink.attach(
        channel: channel,
        password: null,
        readCookie: readTorCookie,
        socks: (host: '127.0.0.1', port: 9050),
      );
      expect(result, isA<TorControlLinked>());
      await (result as TorControlLinked).link.close();
    });

    test('nothing listening is unreachable', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      await expectLater(openTorControl(TorControlTcp('127.0.0.1', port: port)),
          throwsA(isA<TorControlUnreachable>()));
    });

    test('an HTTP server is not tor', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        socket.listen((_) {
          socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
          unawaited(socket.close());
        });
      });
      final channel =
          await openTorControl(TorControlTcp('127.0.0.1', port: server.port));
      final result = await TorControlLink.attach(
        channel: channel,
        password: null,
        readCookie: readTorCookie,
        socks: (host: '127.0.0.1', port: 9050),
      );
      expect((result as TorControlNotLinked).refusal, TorControlRefusal.notTor);
    });
  });
}
