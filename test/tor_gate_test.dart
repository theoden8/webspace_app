// Tor is reachable wherever the platform has the runtime (TOR-007); nothing
// else gates it. The gate lives on TorService, not on the runtime or the
// engine: those answer the narrower "does this build have a tor to talk to",
// which the engine's own tests exercise against a fake.


import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'helpers/fake_tor_runtime.dart';

void main() {
  late FakeTorRuntime runtime;

  void install({bool available = true}) {
    runtime = FakeTorRuntime(isAvailable: available);
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'secret'),
    );
  }

  setUp(install);

  tearDown(() async {
    await TorService.reset();
    await runtime.dispose();
    DeveloperModeService.instance.debugSet(false);
  });

  test('developer mode does not gate Tor', () async {
    DeveloperModeService.instance.debugSet(false);
    expect(TorService.instance.isAvailable, isTrue);
    await TorService.instance.syncHolders({'site-a'});
    expect(runtime.startCalls, 1,
        reason: 'a site pinned to Tor starts it with developer mode off');
  });

  test('turning developer mode off keeps Tor sites routed', () async {
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    runtime.emit(const TorUp('127.0.0.1', 41337));
    await Future<void>.delayed(Duration.zero);

    DeveloperModeService.instance.debugSet(false);
    expect(TorService.instance.socksFor(siteId: 'site-a'), isNotNull);
  });

  group('a platform without the runtime', () {
    setUp(() async {
      await TorService.reset();
      await runtime.dispose();
      install(available: false);
    });

    test('reports Tor unavailable', () {
      expect(TorService.instance.isAvailable, isFalse);
    });

    test('never spawns tor', () async {
      await TorService.instance.maybeStart('site-a');
      await TorService.instance.syncHolders({'site-a', 'site-b'});
      await TorService.instance.restart();
      expect(runtime.startCalls, 0);
    });

    test('never reaches tor with an exit pin', () async {
      await TorService.instance.setExitCountry('{de}');
      expect(runtime.appliedExitNodes, isEmpty);
    });

    test('socksFor fails closed rather than falling back to direct', () {
      // A site carrying ProxyType.TOR imported from an Apple device must be
      // blocked, never quietly sent out over the device IP.
      expect(TorService.instance.socksFor(siteId: 'site-a'), isNull);
    });
  });

  test('the SOCKS settings carry the isolation tag', () async {
    await TorService.instance.syncHolders({'site-a'});
    runtime.emit(const TorUp('127.0.0.1', 41337));
    await Future<void>.delayed(Duration.zero);

    final resolved = TorService.instance.socksFor(siteId: 'site-a')!;
    expect(resolved.type, ProxyType.SOCKS5);
    expect(resolved.username, 'site-a');
  });

  // TOR-022: what the screen in front of a blocked site is allowed to say.
  // The status alone cannot answer it -- `stopped` is a moment inside a
  // start-up where Tor can run, and forever where it cannot.
  group('torGateFor', () {
    test('a platform without tor is unsupported whatever the status', () {
      for (final s in <TorStatus>[
        const TorStopped(),
        TorErrored('bootstrap stalled'),
      ]) {
        expect(torGateFor(status: s, hasNativeTor: false), TorGate.unsupported,
            reason: 'Retry there would do nothing: restart() returns at the '
                'same gate');
      }
    });

    test('an error where tor exists is one', () {
      expect(
        torGateFor(status: TorErrored('bootstrap stalled'), hasNativeTor: true),
        TorGate.errored,
      );
    });

    test('a runtime that can come up is working, whatever it is doing', () {
      for (final s in <TorStatus>[
        const TorStopped(),
        const TorStarting(),
        const TorBootstrapping(40),
        const TorUp('127.0.0.1', 41337),
      ]) {
        expect(torGateFor(status: s, hasNativeTor: true), TorGate.working);
      }
    });
  });
}
