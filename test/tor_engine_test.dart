// TOR-002 lifecycle, TOR-003 stream isolation, TOR-008 fail-closed.
//
// The fake models the runtime's contract rather than stubbing it: start/stop
// are recorded, and status is pushed the way the native side pushes it, so a
// test can drive a real bootstrap sequence and a real late-event race.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/settings/proxy.dart';

class FakeTorRuntime implements TorRuntime {
  FakeTorRuntime({this.isAvailable = true});

  @override
  final bool isAvailable;

  final _controller = StreamController<TorStatus>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int rebuildCalls = 0;
  Object? startError;
  final appliedExitNodes = <String?>[];
  Object? exitCountryError;

  @override
  Stream<TorStatus> get events => _controller.stream;

  @override
  Future<void> start() async {
    startCalls++;
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> rebuildCircuits() async => rebuildCalls++;

  @override
  Future<void> applyExitCountry(String? exitNodes) async {
    if (exitCountryError != null) throw exitCountryError!;
    appliedExitNodes.add(exitNodes);
  }

  /// Push a status the way the native event channel would.
  void push(TorStatus s) => _controller.add(s);

  /// Drive a full successful bootstrap.
  void bootstrapTo(int port) {
    push(const TorBootstrapping(10));
    push(const TorBootstrapping(80));
    push(TorUp('127.0.0.1', port));
  }

  void dispose() => _controller.close();
}

void main() {
  late FakeTorRuntime runtime;

  setUp(() => runtime = FakeTorRuntime());
  tearDown(() => runtime.dispose());

  TorEngine build({Duration? debounce, Duration? timeout}) => TorEngine(
        runtime: runtime,
        sessionSecret: 'deadbeef',
        idleDebounce: debounce ?? kTorIdleDebounce,
        bootstrapTimeout: timeout ?? kTorBootstrapTimeout,
      );

  group('TOR-002 lifecycle', () {
    test('first holder starts the runtime', () async {
      final e = build();
      expect(e.status, isA<TorStopped>());

      await e.acquire('site-a');
      expect(runtime.startCalls, 1);
      expect(e.status, isA<TorStarting>());

      runtime.bootstrapTo(9999);
      await pumpEventQueue();
      expect(e.status, isA<TorUp>());
      await e.dispose();
    });

    test('a second holder does not restart a running runtime', () async {
      final e = build();
      await e.acquire('site-a');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      await e.acquire('site-b');
      expect(runtime.startCalls, 1, reason: 'still one start');
      expect(e.holders, {'site-a', 'site-b'});
      await e.dispose();
    });

    test('acquiring the same reason twice counts once', () async {
      final e = build();
      await e.acquire('site-a');
      await e.acquire('site-a');
      expect(e.holders, {'site-a'});

      // One release must therefore fully release it, not leave a phantom
      // holder pinning the runtime up forever.
      e.release('site-a');
      expect(e.holders, isEmpty);
      await e.dispose();
    });

    test('releasing the last holder debounces, then stops', () {
      fakeAsync((async) {
        final e = build(debounce: const Duration(seconds: 60));
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();
        expect(e.status, isA<TorUp>());

        e.release('site-a');
        async.elapse(const Duration(seconds: 59));
        expect(e.status, isA<TorUp>(), reason: 'still up during debounce');
        expect(runtime.stopCalls, 0);

        async.elapse(const Duration(seconds: 2));
        expect(runtime.stopCalls, 1);
        expect(e.status, isA<TorStopped>());
      });
    });

    test('reacquiring during the debounce cancels the shutdown', () {
      fakeAsync((async) {
        final e = build(debounce: const Duration(seconds: 60));
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();

        e.release('site-a');
        async.elapse(const Duration(seconds: 30));
        e.acquire('site-b');
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 120));
        expect(runtime.stopCalls, 0, reason: 'never shut down');
        expect(runtime.startCalls, 1, reason: 'no second bootstrap');
        expect(e.status, isA<TorUp>());
      });
    });

    test('syncHolders reconciles the whole set', () async {
      final e = build();
      await e.syncHolders({'a', 'b'});
      expect(e.holders, {'a', 'b'});

      await e.syncHolders({'b', 'c'});
      expect(e.holders, {'b', 'c'});
      expect(runtime.startCalls, 1, reason: 'never dropped to zero');
      await e.dispose();
    });

    test('an unavailable runtime is never started', () async {
      runtime = FakeTorRuntime(isAvailable: false);
      final e = build();
      await e.acquire('site-a');
      expect(runtime.startCalls, 0);
      expect(e.holders, isEmpty);
      expect(e.status, isA<TorStopped>());
      await e.dispose();
    });

    test('a start that throws surfaces as an error, not a hang', () async {
      runtime.startError = StateError('no tor for you');
      final e = build();
      await e.acquire('site-a');
      expect(e.status, isA<TorErrored>());
      await e.dispose();
    });
  });

  group('TOR-013 bootstrap timeout', () {
    test('bootstrap that never completes errors out and stops', () {
      fakeAsync((async) {
        final e = build(timeout: const Duration(seconds: 90));
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.push(const TorBootstrapping(40));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 89));
        expect(e.status, isA<TorBootstrapping>());

        async.elapse(const Duration(seconds: 2));
        expect(e.status, isA<TorErrored>());
        expect(runtime.stopCalls, 1, reason: 'the dead thread is torn down');
      });
    });

    test('reaching up cancels the timeout', () {
      fakeAsync((async) {
        final e = build(timeout: const Duration(seconds: 90));
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 10));
        expect(e.status, isA<TorUp>(), reason: 'no late timeout fires');
      });
    });
  });

  group('TOR-003 stream isolation', () {
    test('distinct sites get distinct SOCKS usernames on one endpoint', () async {
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      final a = e.socksFor('a1')!;
      final b = e.socksFor('b2')!;

      expect(a.username, 'a1');
      expect(b.username, 'b2');
      expect(a.username, isNot(b.username));
      expect(a.address, b.address, reason: 'same listener, different circuits');
      expect(a.type, ProxyType.SOCKS5);
      await e.dispose();
    });

    test('app-global traffic never borrows a site tag', () async {
      final e = build();
      await e.acquire(kTorAppGlobalTag);
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      expect(e.socksFor(kTorAppGlobalTag)!.username, kTorAppGlobalTag);
      expect(TorEngine.tagFor(null), kTorAppGlobalTag);
      expect(TorEngine.tagFor(''), kTorAppGlobalTag);
      expect(TorEngine.tagFor('site-x'), 'site-x');
      await e.dispose();
    });

    test('the session secret is the SOCKS password for every tag', () async {
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      expect(e.socksFor('a1')!.password, 'deadbeef');
      expect(e.socksFor('b2')!.password, 'deadbeef');
      await e.dispose();
    });

    test('never reports the well-known 9050', () async {
      // Nothing may hardcode Tor's default port: the embedded runtime picks
      // its own, and 9050 may belong to some other app on the device.
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(41337);
      await pumpEventQueue();

      expect(e.socksFor('a1')!.address, '127.0.0.1:41337');
      expect(e.socksFor('a1')!.address, isNot(contains('9050')));
      await e.dispose();
    });
  });

  group('TOR-008 fail-closed', () {
    test('socksFor yields nothing until the runtime is up', () async {
      final e = build();
      expect(e.socksFor('a1'), isNull, reason: 'stopped');

      await e.acquire('a1');
      expect(e.socksFor('a1'), isNull, reason: 'starting');

      runtime.push(const TorBootstrapping(50));
      await pumpEventQueue();
      expect(e.socksFor('a1'), isNull, reason: 'mid-bootstrap');

      runtime.push(TorUp('127.0.0.1', 9999));
      await pumpEventQueue();
      expect(e.socksFor('a1'), isNotNull);
      await e.dispose();
    });

    test('an errored runtime yields nothing', () async {
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();
      expect(e.socksFor('a1'), isNotNull);

      runtime.push(const TorErrored('control port died'));
      await pumpEventQueue();
      expect(e.socksFor('a1'), isNull,
          reason: 'an error must not keep serving a stale endpoint');
      await e.dispose();
    });

    test('a status arriving after shutdown cannot resurrect the endpoint', () {
      fakeAsync((async) {
        final e = build(debounce: const Duration(seconds: 60));
        e.acquire('a1');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();

        e.release('a1');
        async.elapse(const Duration(seconds: 61));
        expect(e.status, isA<TorStopped>());

        // An in-flight native event racing the shutdown.
        runtime.push(TorUp('127.0.0.1', 9999));
        async.flushMicrotasks();

        expect(e.status, isA<TorStopped>());
        expect(e.socksFor('a1'), isNull);
      });
    });
  });

  test('rebuildCircuits is a no-op unless the runtime is up', () async {
    final e = build();
    await e.rebuildCircuits();
    expect(runtime.rebuildCalls, 0);

    await e.acquire('a1');
    runtime.bootstrapTo(9999);
    await pumpEventQueue();
    await e.rebuildCircuits();
    expect(runtime.rebuildCalls, 1);
    await e.dispose();
  });

  group('TOR-014 exit-country pin', () {
    test('a pin set while up reaches the runtime', () async {
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      await e.setExitCountry('{de}');
      expect(runtime.appliedExitNodes, ['{de}']);
      expect(e.exitNodes, '{de}');
      await e.dispose();
    });

    test('a pin set before bootstrap is applied on reaching up', () async {
      // SETCONF needs a live control port; a pin requested earlier must be
      // deferred rather than dropped, or the user gets no pin at all.
      final e = build();
      await e.acquire('a1');
      await e.setExitCountry('{nl}');
      expect(runtime.appliedExitNodes, isEmpty, reason: 'no control port yet');

      runtime.bootstrapTo(9999);
      await pumpEventQueue();
      await pumpEventQueue();
      expect(runtime.appliedExitNodes, ['{nl}']);
      await e.dispose();
    });

    test('re-setting the same pin does not re-issue SETCONF', () async {
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      await e.setExitCountry('{de}');
      await e.setExitCountry('{de}');
      expect(runtime.appliedExitNodes, ['{de}'], reason: 'idempotent');
      await e.dispose();
    });

    test('clearing the pin resets it rather than leaving it set', () async {
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      await e.setExitCountry('{de}');
      await e.setExitCountry(null);
      expect(runtime.appliedExitNodes, ['{de}', null]);
      expect(e.exitNodes, isNull);
      await e.dispose();
    });

    test('a pin that fails to apply surfaces, never reads as in force', () async {
      // Reporting an unapplied pin as live would tell the user traffic is
      // leaving from a country it is not.
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      runtime.exitCountryError = StateError('control port said no');
      await e.setExitCountry('{de}');
      expect(e.status, isA<TorErrored>());
      await e.dispose();
    });

    test('a restart re-applies the pin to the new instance', () {
      // tor is gone, and the ExitNodes it held went with it.
      fakeAsync((async) {
        final e = build(debounce: const Duration(seconds: 60));
        e.acquire('a1');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();
        e.setExitCountry('{de}');
        async.flushMicrotasks();
        expect(runtime.appliedExitNodes, ['{de}']);

        e.release('a1');
        async.elapse(const Duration(seconds: 61));
        expect(e.status, isA<TorStopped>());

        e.acquire('a2');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(runtime.appliedExitNodes, ['{de}', '{de}'],
            reason: 'the pin is re-applied, not assumed still live');
      });
    });

    test('an unavailable runtime is never configured', () async {
      runtime = FakeTorRuntime(isAvailable: false);
      final e = build();
      await e.setExitCountry('{de}');
      expect(runtime.appliedExitNodes, isEmpty);
      await e.dispose();
    });
  });
}
