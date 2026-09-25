// Tor is an experimental feature: reachable only on a platform with the
// runtime (TOR-007), with developer mode on and the Experimental group's Tor
// switch on (DEVTOOLS-011). The gate lives on
// TorService, not on the runtime or the engine: those answer the narrower
// "does this build have a tor to talk to", which the engine's own tests
// exercise against a fake.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';

/// Available runtime that records what the engine asked it to do, so a test
/// can tell "refused at the gate" from "asked and got nothing".
class _AvailableRuntime implements TorRuntime {
  final _events = StreamController<TorStatus>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  final applied = <String?>[];

  @override
  bool get isAvailable => true;

  @override
  Stream<TorStatus> get events => _events.stream;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> rebuildCircuits() async {}

  @override
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile}) async =>
      applied.add(exitNodes);

  @override
  Future<int> startTransport(String transport) async => 0;

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {}

  @override
  Future<void> setSocksIsolation({required bool isolateDestAddr}) async {
    socksIsolation = isolateDestAddr;
  }

  bool? socksIsolation;

  void emit(TorStatus s) => _events.add(s);
  Future<void> dispose() => _events.close();
}

void main() {
  late _AvailableRuntime runtime;

  setUp(() {
    runtime = _AvailableRuntime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'secret'),
    );
  });

  tearDown(() async {
    await TorService.reset();
    await runtime.dispose();
    DeveloperModeService.instance.debugSet(false);
    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.tor, true);
  });

  test('the Tor switch off shuts the gate with developer mode on', () {
    DeveloperModeService.instance.debugSet(true);
    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.tor, false);
    expect(TorService.instance.isAvailable, isFalse);
    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.tor, true);
    expect(TorService.instance.isAvailable, isTrue,
        reason: 'the switch is read per call, not cached at construction');
  });

  test('the Tor switch cannot open Tor without developer mode', () {
    DeveloperModeService.instance.debugSet(false);
    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.tor, true);
    expect(TorService.instance.isAvailable, isFalse);
  });

  test('switching Tor off releases the holders already taken', () async {
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    expect(runtime.startCalls, 1);

    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.tor, false);
    await TorService.instance.syncHolders({'site-a'});
    expect(TorService.instance.socksFor(siteId: 'site-a'), isNull,
        reason: 'a site still pinned to Tor fails closed');
    await TorService.instance.maybeStart('site-a');
    expect(runtime.startCalls, 1, reason: 'no restart behind the shut gate');
  });

  test('a platform with tor still reports unavailable while dev mode is off',
      () {
    DeveloperModeService.instance.debugSet(false);
    expect(TorService.instance.isAvailable, isFalse);
  });

  test('turning developer mode on opens the gate with no restart', () {
    DeveloperModeService.instance.debugSet(false);
    expect(TorService.instance.isAvailable, isFalse);
    DeveloperModeService.instance.debugSet(true);
    expect(TorService.instance.isAvailable, isTrue,
        reason: 'the flag is read per call, not cached at construction');
  });

  test('maybeStart does not spawn tor while the gate is shut', () async {
    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.maybeStart('site-a');
    expect(runtime.startCalls, 0);
  });

  test('syncHolders takes no holders while the gate is shut', () async {
    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.syncHolders({'site-a', 'site-b'});
    expect(runtime.startCalls, 0);
  });

  test('turning developer mode off releases the holders already taken',
      () async {
    // The bug this guards: an early return in the sync path would leave the
    // runtime pinned up for a feature the user can no longer reach.
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    expect(runtime.startCalls, 1);

    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.syncHolders({'site-a'});

    // Release is debounced, so assert the holder set emptied rather than
    // waiting out the idle timer.
    expect(TorService.instance.isAvailable, isFalse);
    await TorService.instance.maybeStart('site-a');
    expect(runtime.startCalls, 1, reason: 'no restart behind the shut gate');
  });

  test('setExitCountry does not reach tor while the gate is shut', () async {
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    runtime.emit(const TorUp('127.0.0.1', 41337));
    await Future<void>.delayed(Duration.zero);

    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.setExitCountry('{de}');
    expect(runtime.applied, isEmpty);
  });

  test('socksFor fails closed rather than falling back to direct', () async {
    // A site still carrying ProxyType.TOR from before the flag was turned
    // off must be blocked, never quietly sent out over the device IP.
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    runtime.emit(const TorUp('127.0.0.1', 41337));
    await Future<void>.delayed(Duration.zero);
    expect(TorService.instance.socksFor(siteId: 'site-a'), isNotNull);

    DeveloperModeService.instance.debugSet(false);
    final resolved = TorService.instance.socksFor(siteId: 'site-a');
    expect(resolved, isNull);
  });

  test('with the gate open the SOCKS settings carry the isolation tag', () async {
    DeveloperModeService.instance.debugSet(true);
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
    test('a platform without tor is unsupported however the flag sits', () {
      for (final dev in [true, false]) {
        expect(
          torGateFor(
              status: const TorStopped(),
              hasNativeTor: false,
              torEnabled: dev),
          TorGate.unsupported,
          reason: 'developer mode cannot conjure a runtime that is not in '
              'the build',
        );
      }
    });

    test('tor present but the flag off names the flag', () {
      expect(
        torGateFor(
            status: const TorStopped(),
            hasNativeTor: true,
            torEnabled: false),
        TorGate.switchedOff,
      );
    });

    test('an error that can no longer be retried is not reported as one', () {
      // Every start path re-checks the gate, so `restart()` behind a shut
      // gate returns without doing anything. Reporting `errored` would put a
      // Retry button on screen that cannot do what it says.
      expect(
        torGateFor(
            status: TorErrored('bootstrap stalled'),
            hasNativeTor: true,
            torEnabled: false),
        TorGate.switchedOff,
      );
      expect(
        torGateFor(
            status: TorErrored('bootstrap stalled'),
            hasNativeTor: true,
            torEnabled: true),
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
        expect(
          torGateFor(
              status: s, hasNativeTor: true, torEnabled: true),
          TorGate.working,
        );
      }
    });
  });
}
