// TOR-025: Tor sites through a tor started outside the app.
//
// The engine is the real one; only the socket answer is faked, so these
// drive the same acquire, pin and revive paths the embedded runtime takes.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/tor_socks_probe_io.dart';
import 'package:webspace/settings/proxy.dart';
import 'helpers/fake_tor_runtime.dart';

class _Answers {
  _Answers(this.answer);

  ExternalTorAnswer answer;
  final asked = <String>[];

  Future<ExternalTorAnswer> call(String host, int port) async {
    asked.add('$host:$port');
    return answer;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late String address;
  late _Answers answers;
  late ExternalTorRuntime runtime;
  late TorEngine engine;
  late bool listenerAlive;

  setUp(() {
    address = '127.0.0.1:9050';
    answers = _Answers(ExternalTorAnswer.tor);
    listenerAlive = true;
    runtime = ExternalTorRuntime(address: () => address, identify: answers.call);
    engine = TorEngine(
      runtime: runtime,
      sessionSecret: 'secret',
      socksProbe: (_, _) async => listenerAlive,
    );
  });

  tearDown(() => engine.dispose());

  Future<TorStatus> settled(Future<void> Function() action) {
    final next =
        engine.statusStream.firstWhere((s) => s is TorUp || s is TorErrored);
    return action().then((_) => next);
  }

  test('an external tor that answers comes up at its own address', () async {
    final s = await settled(() => engine.acquire(TorSiteHolder('site-a')));
    expect(s, isA<TorUp>());
    expect((s as TorUp).host, '127.0.0.1');
    expect(s.port, 9050);
    expect(answers.asked, ['127.0.0.1:9050']);
  });

  test('each site presents its own credential to that tor', () async {
    await settled(() => engine.acquire(TorSiteHolder('site-a')));
    final a = engine.socksFor('site-a')!;
    final b = engine.socksFor('site-b')!;
    final global = engine.socksFor(kTorAppGlobalTag)!;
    for (final s in [a, b, global]) {
      expect(s.type, ProxyType.SOCKS5);
      expect(s.address, '127.0.0.1:9050');
      expect(s.password, isNotEmpty);
    }
    expect({a.username, b.username, global.username}, hasLength(3),
        reason: 'IsolateSOCKSAuth keys circuits on the credential');
    expect({a.password, b.password, global.password}, hasLength(3));
  });

  test('nothing answering fails closed', () async {
    answers.answer = ExternalTorAnswer.unreachable;
    final s = await settled(() => engine.acquire(TorSiteHolder('site-a')));
    expect(s, isA<TorErrored>());
    expect((s as TorErrored).kind, TorFailureKind.externalUnreachable);
    expect(engine.socksFor('site-a'), isNull);
  });

  test('a SOCKS proxy that is not tor is never called Tor', () async {
    answers.answer = ExternalTorAnswer.notTor;
    final s = await settled(() => engine.acquire(TorSiteHolder('site-a')));
    expect((s as TorErrored).kind, TorFailureKind.externalUnreachable);
    expect(engine.socksFor('site-a'), isNull);
  });

  test('a malformed address is never dialled', () async {
    address = 'localhost';
    final s = await settled(() => engine.acquire(TorSiteHolder('site-a')));
    expect((s as TorErrored).kind, TorFailureKind.externalUnreachable);
    expect(answers.asked, isEmpty);
  });

  test('an exit pin holds the sites rather than leave from any country',
      () async {
    await settled(() => engine.acquire(TorSiteHolder('site-a')));
    final pinned = await settled(() => engine.setExitCountry('{de}'));
    expect((pinned as TorErrored).kind, TorFailureKind.externalExitPin);
    expect(engine.socksFor('site-a'), isNull);

    final cleared = await settled(() => engine.setExitCountry(null));
    expect(cleared, isA<TorUp>());
    expect(engine.socksFor('site-a'), isNotNull);
  });

  test('a changed address is asked again and its endpoint published',
      () async {
    await settled(() => engine.acquire(TorSiteHolder('site-a')));
    address = '127.0.0.1:9150';
    final s = await settled(runtime.reconnect);
    expect((s as TorUp).port, 9150);
    expect(engine.socksFor('site-a')!.address, '127.0.0.1:9150');
  });

  test('an answer for an address since replaced is dropped', () async {
    final pending = <String, Completer<ExternalTorAnswer>>{};
    final r = ExternalTorRuntime(
      address: () => address,
      identify: (host, port) =>
          (pending['$host:$port'] = Completer<ExternalTorAnswer>()).future,
    );
    final seen = <TorStatus>[];
    final sub = r.events.listen(seen.add);
    unawaited(r.start());
    address = '127.0.0.1:9150';
    unawaited(r.reconnect());
    await Future<void>.delayed(Duration.zero);
    pending['127.0.0.1:9150']!.complete(ExternalTorAnswer.tor);
    await Future<void>.delayed(Duration.zero);
    pending['127.0.0.1:9050']!.complete(ExternalTorAnswer.unreachable);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, hasLength(1));
    expect((seen.single as TorUp).port, 9150);
  });

  test('a tor that went away while the app was out fails closed on return',
      () async {
    await settled(() => engine.acquire(TorSiteHolder('site-a')));
    listenerAlive = false;
    answers.answer = ExternalTorAnswer.unreachable;
    final s = await settled(engine.revive);
    expect((s as TorErrored).kind, TorFailureKind.externalUnreachable);
    expect(engine.socksFor('site-a'), isNull);
  });

  group('TorService', () {
    tearDown(TorService.reset);

    test('offers Tor and says it is an existing one', () async {
      TorService.overrideEngine(engine, external: runtime);
      expect(TorService.instance.isAvailable, isTrue);
      expect(TorService.instance.isExternal, isTrue);
      await settled(() => TorService.instance.maybeStart(TorSiteHolder('site-a')));
      final s = TorService.instance.socksFor(siteId: 'site-a')!;
      expect(s.username, 'site-a');
    });

    test('an address change while nothing uses Tor asks nothing', () async {
      TorService.overrideEngine(engine, external: runtime);
      await TorService.instance.externalAddressChanged();
      expect(answers.asked, isEmpty);
    });
  });

  group('switching tor without a relaunch', () {
    late FakeTorRuntime embeddedRuntime;
    late TorEngine embedded;
    late bool wantExternal;

    setUp(() {
      embeddedRuntime = FakeTorRuntime(
          onStart: (r) => r.emit(const TorUp('127.0.0.1', 39999)));
      embedded = TorEngine(runtime: embeddedRuntime, sessionSecret: 'e');
      wantExternal = false;
      TorService.wantsExternal = () => wantExternal;
      TorService.overrideEngines(
          embedded: embedded, external: engine, externalRuntime: runtime);
    });

    tearDown(TorService.reset);

    test('the sites move to the external tor and back', () async {
      final tor = TorService.instance;
      await tor.syncHolders({TorSiteHolder('site-a'), TorSiteHolder('site-b')});
      await _settle();
      expect(tor.isExternal, isFalse);
      expect(tor.socksFor(siteId: 'site-a')!.address, '127.0.0.1:39999');

      wantExternal = true;
      await tor.runtimeChoiceChanged();
      await _settle();
      expect(tor.isExternal, isTrue);
      expect(tor.socksFor(siteId: 'site-a')!.address, '127.0.0.1:9050');
      expect(engine.holders, {TorSiteHolder('site-a'), TorSiteHolder('site-b')});
      expect(embedded.holders, isEmpty);

      wantExternal = false;
      await tor.runtimeChoiceChanged();
      await _settle();
      expect(tor.socksFor(siteId: 'site-a')!.address, '127.0.0.1:39999');
      expect(embedded.holders, {TorSiteHolder('site-a'), TorSiteHolder('site-b')});
      expect(embeddedRuntime.stopCalls, 0,
          reason: 'TOR-020: the built-in tor runs once per process');
      expect(embeddedRuntime.startCalls, 1,
          reason: 'the idle built-in tor is reused, never started again');
    });

    test('listeners hear the switch, and only the chosen tor', () async {
      final tor = TorService.instance;
      final heard = <TorStatus>[];
      final sub = tor.statusStream.listen(heard.add);
      await engine.acquire(TorSiteHolder('not-through-the-service'));
      await _settle();
      expect(heard, isEmpty, reason: 'the external tor is not chosen');

      wantExternal = true;
      await tor.runtimeChoiceChanged();
      await _settle();
      await sub.cancel();
      expect(heard.last, isA<TorUp>());
      expect((heard.last as TorUp).port, 9050);
    });

    test('a pin asked of the built-in tor holds the sites on the external one',
        () async {
      final tor = TorService.instance;
      await tor.syncHolders({TorSiteHolder('site-a')});
      await tor.setExitCountry('{de}');
      await _settle();
      expect(embeddedRuntime.appliedExitNodes, ['{de}']);

      wantExternal = true;
      await tor.runtimeChoiceChanged();
      await _settle();
      expect((tor.status as TorErrored).kind, TorFailureKind.externalExitPin);
      expect(tor.socksFor(siteId: 'site-a'), isNull);
    });

    test('a flip during a flip lands on the last one', () async {
      final tor = TorService.instance;
      await tor.syncHolders({TorSiteHolder('site-a')});
      await _settle();

      wantExternal = true;
      final first = tor.runtimeChoiceChanged();
      wantExternal = false;
      final second = tor.runtimeChoiceChanged();
      await Future.wait([first, second]);
      await _settle();
      expect(tor.isExternal, isFalse);
      expect(embedded.holders, {TorSiteHolder('site-a')});
      expect(engine.holders, isEmpty);
    });
  });

  group('identifyTor', () {
    Future<int> serve(List<int> reply) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        socket.listen((_) {
          socket.add(reply);
          socket.close();
        });
      });
      return server.port;
    }

    test('tor\'s refusal of HTTP names it', () async {
      final port = await serve(
          'HTTP/1.0 501 Tor is not an HTTP Proxy\r\nContent-Type: text/html; '
                  'charset=iso-8859-1\r\n\r\n<html></html>'
              .codeUnits);
      expect(await identifyTor('127.0.0.1', port), ExternalTorAnswer.tor);
    });

    test('any other answer is not tor', () async {
      final port = await serve('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits);
      expect(await identifyTor('127.0.0.1', port), ExternalTorAnswer.notTor);
    });

    test('a SOCKS-only reply is not tor', () async {
      final port = await serve(const [5, 255]);
      expect(await identifyTor('127.0.0.1', port), ExternalTorAnswer.notTor);
    });

    test('a closed port is unreachable', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      expect(
          await identifyTor('127.0.0.1', port), ExternalTorAnswer.unreachable);
    });
  });
}
