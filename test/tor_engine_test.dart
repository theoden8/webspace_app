// TOR-002 lifecycle, TOR-003 stream isolation, TOR-008 fail-closed.
//
// The fake models the runtime's contract rather than stubbing it: start/stop
// are recorded, and status is pushed the way the native side pushes it, so a
// test can drive a real bootstrap sequence and a real late-event race.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_geoip.dart';
import 'package:webspace/settings/proxy.dart';
import 'helpers/fake_tor_runtime.dart';

/// In-memory [TorGeoIpStore]: one kept table at most, and a download the
/// test answers by completing [nextDownload].
class FakeGeoIpStore implements TorGeoIpStore {
  TorGeoIpTable? kept;
  final downloads = <UserProxySettings>[];
  Completer<TorGeoIpTable?>? nextDownload;

  @override
  Future<TorGeoIpTable?> newest() async => kept;

  @override
  Future<TorGeoIpTable?> download(UserProxySettings via) async {
    downloads.add(via);
    final table = await (nextDownload ??= Completer<TorGeoIpTable?>()).future;
    nextDownload = null;
    if (table != null) kept = table;
    return table;
  }
}

void main() {
  late FakeTorRuntime runtime;

  setUp(() => runtime = FakeTorRuntime());
  tearDown(() => runtime.dispose());

  TorEngine build({
    Duration? debounce,
    Duration? timeout,
    TorGeoIpStore? geoIpStore,
    DateTime Function()? clock,
    TorSocksProbe? socksProbe,
  }) =>
      TorEngine(
        runtime: runtime,
        sessionSecret: 'deadbeef',
        idleDebounce: debounce ?? kTorIdleDebounce,
        bootstrapTimeout: timeout ?? kTorBootstrapTimeout,
        geoIpStore: geoIpStore,
        clock: clock,
        socksProbe: socksProbe,
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

    test('releasing the last holder never stops the runtime', () {
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

        // And still up afterwards. tor runs at most once per process
        // (BUG-013), so an idle stop spends the app's only launch and the
        // next site pinned to Tor gets a runtime that cannot come back.
        async.elapse(const Duration(seconds: 2));
        expect(runtime.stopCalls, 0);
        expect(e.status, isA<TorUp>());
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
    test('bootstrap that never completes errors out, tor left running', () {
      fakeAsync((async) {
        final e = build(timeout: const Duration(seconds: 90));
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.emit(const TorBootstrapping(40));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 89));
        expect(e.status, isA<TorBootstrapping>());

        async.elapse(const Duration(seconds: 2));
        expect(e.status, isA<TorErrored>());
        expect(runtime.stopCalls, 0,
            reason: 'the deadline is a report, not a teardown: tor keeps '
                'retrying and there is no second launch to spend');
      });
    });

    test('a Retry on a live runtime does not strand it in starting', () {
      // The runtime's start() is a no-op while tor is alive, so a Retry that
      // published `starting` and armed the deadline would sit there until it
      // reported a bootstrap failure against a tor that was working.
      fakeAsync((async) {
        final e = build(timeout: const Duration(seconds: 90));
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();
        expect(e.status, isA<TorUp>());

        e.restart();
        async.flushMicrotasks();
        expect(e.status, isA<TorUp>(), reason: 'a Retry must not blank it');

        async.elapse(const Duration(minutes: 5));
        expect(e.status, isA<TorUp>(),
            reason: 'and must not arm a deadline that then fails it');
        expect(runtime.stopCalls, 0);
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

    test('the SOCKS password is derived per tag, not shared', () async {
      // This test used to assert the opposite — that the launch secret was
      // handed out verbatim as every tag's password. Isolation never
      // depended on that (tor keys circuits on the whole username+password
      // tuple, and the usernames already differ), but containment did:
      // siteIds are not secret, so anything that learned the one shared
      // secret could pair it with any siteId and ride that site's circuit.
      // The password is now HMAC(launch secret, tag), which confines a leak
      // to the site it came from. Derivation details live in
      // test/tor_failure_test.dart.
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      expect(e.socksFor('a1')!.password, isNot('deadbeef'),
          reason: 'the launch secret itself must never go on the wire');
      expect(e.socksFor('a1')!.password, isNot(e.socksFor('b2')!.password));
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

      runtime.emit(const TorBootstrapping(50));
      await pumpEventQueue();
      expect(e.socksFor('a1'), isNull, reason: 'mid-bootstrap');

      runtime.emit(TorUp('127.0.0.1', 9999));
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

      runtime.emit(TorErrored('control port died'));
      await pumpEventQueue();
      expect(e.socksFor('a1'), isNull,
          reason: 'an error must not keep serving a stale endpoint');
      await e.dispose();
    });

    test('a status arriving after teardown reaches nothing', () async {
      // The stream is closed by then, so an in-flight native event would be
      // an "add after close" thrown from a listener nobody owns. Holders no
      // longer say anything about this: releasing the last one leaves tor
      // running, so the engine's own teardown is the only shutdown left.
      final e = build(debounce: const Duration(seconds: 60));
      await e.acquire('a1');
      await pumpEventQueue();
      runtime.bootstrapTo(9999);
      await pumpEventQueue();
      expect(e.status, isA<TorUp>());

      await e.dispose();
      runtime.emit(TorErrored('control port died'));
      await pumpEventQueue();
      expect(e.status, isA<TorUp>(),
          reason: 'a disposed engine no longer tracks the runtime');
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

    test('a pin to a country with no exit is the country\'s failure, and a '
        'Retry counts again', () async {
      // TOR-014. The pin is in force and tor builds no circuit under it; the
      // card has to name the country as the problem, not the control port.
      final e = build();
      await e.acquire('a1');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();

      runtime.exitCountryError =
          const TorExitCountryEmpty('tor lists no exit relay in BR');
      await e.setExitCountry('{br}');
      final status = e.status;
      expect(status, isA<TorErrored>());
      expect((status as TorErrored).kind, TorFailureKind.exitPolicy);
      expect(status.message, 'tor lists no exit relay in BR',
          reason: 'it applied, so it must not read as "could not apply"');
      expect(e.socksFor('a1'), isNull,
          reason: 'a site pinned where no exit is must not get a route');

      runtime.exitCountryError = null;
      await e.restart();
      expect(runtime.appliedExitNodes, ['{br}'],
          reason: 'a Retry re-applies the pin, which counts the exits again');
      expect(e.status, isA<TorUp>());
      await e.dispose();
    });

    test('a restart re-applies the pin to the instance that comes back', () {
      // A restart cannot assume the pin survived: whatever tor answers, the
      // SETCONF that carried it belonged to the run that failed.
      fakeAsync((async) {
        final e = build(debounce: const Duration(seconds: 60));
        e.acquire('a1');
        async.flushMicrotasks();
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();
        e.setExitCountry('{de}');
        async.flushMicrotasks();
        expect(runtime.appliedExitNodes, ['{de}']);

        // A Retry is a no-op on a live runtime, so drive the case it is
        // actually for: tor reported a failure, and whatever comes back is a
        // runtime whose ExitNodes nobody has set.
        runtime.emit(TorErrored('control port died'));
        async.flushMicrotasks();

        e.restart();
        async.flushMicrotasks();
        expect(runtime.stopCalls, 0,
            reason: 'a restart never stops tor: the process has one launch '
                'and a stop spends it (BUG-013)');
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

  group('TOR-014 exit-country GeoIP', () {
    final fetchedAt = DateTime.utc(2026, 9, 1);
    final table = TorGeoIpTable('/cache/tor_geoip/geoip-1', fetchedAt);

    Future<TorEngine> upWith(FakeGeoIpStore store, {DateTime? now}) async {
      final e = build(geoIpStore: store, clock: () => now ?? fetchedAt);
      await e.acquire('site-a');
      runtime.bootstrapTo(9999);
      await pumpEventQueue();
      return e;
    }

    test('sites are held off Tor until the pin lands', () async {
      // The reported bug: a site pinned to Brazil kept loading through the
      // Dutch exit it had before. Nothing may use Tor between the request
      // for a country and tor having it.
      final store = FakeGeoIpStore();
      final e = await upWith(store);
      expect(e.socksFor('site-a'), isNotNull);

      final pinning = e.setExitCountry('{br}');
      await pumpEventQueue();
      expect(e.status, isA<TorBootstrapping>());
      expect((e.status as TorBootstrapping).tag, kTorExitPinTag);
      expect(e.socksFor('site-a'), isNull, reason: 'held while pending');
      expect(runtime.appliedExitNodes, isEmpty,
          reason: 'no pin before tor can resolve it');

      store.nextDownload!.complete(table);
      await pinning;
      expect(runtime.appliedExitNodes, ['{br}']);
      expect(runtime.appliedGeoIpFiles, [table.path]);
      expect(e.status, isA<TorUp>());
      expect(e.socksFor('site-a'), isNotNull);
      await e.dispose();
    });

    test('the download rides Tor on its own circuit', () async {
      final store = FakeGeoIpStore();
      final e = await upWith(store);
      final pinning = e.setExitCountry('{br}');
      await pumpEventQueue();

      final via = store.downloads.single;
      expect(via.type, ProxyType.SOCKS5);
      expect(via.address, '127.0.0.1:9999');
      expect(via.username, kTorGeoIpTag);
      expect(via.password, isNot(e.socksFor('site-a')?.password));
      store.nextDownload!.complete(table);
      await pinning;
      await e.dispose();
    });

    test('a kept table is used without a download', () async {
      final store = FakeGeoIpStore()..kept = table;
      final e = await upWith(store);
      await e.setExitCountry('{br}');
      expect(store.downloads, isEmpty);
      expect(runtime.appliedGeoIpFiles, [table.path]);
      expect(e.status, isA<TorUp>());
      await e.dispose();
    });

    test('a stale table is used now and refreshed behind it', () async {
      final store = FakeGeoIpStore()..kept = table;
      final e = await upWith(store,
          now: fetchedAt.add(kTorGeoIpMaxAge + const Duration(days: 1)));
      await e.setExitCountry('{br}');
      expect(runtime.appliedGeoIpFiles, [table.path]);
      expect(e.status, isA<TorUp>(), reason: 'a refresh never holds a site');
      expect(store.downloads, hasLength(1));
      store.nextDownload!.complete(null);
      await e.dispose();
    });

    test('no table, no pin: the failure names the data, not the country',
        () async {
      final store = FakeGeoIpStore();
      final e = await upWith(store);
      final pinning = e.setExitCountry('{br}');
      await pumpEventQueue();
      store.nextDownload!.complete(null);
      await pinning;

      expect(runtime.appliedExitNodes, isEmpty);
      expect(e.status, isA<TorErrored>());
      expect((e.status as TorErrored).kind, TorFailureKind.exitCountryData);
      expect(e.socksFor('site-a'), isNull, reason: 'fails closed');
      await e.dispose();
    });

    test('the same pin after a failure waits for Retry', () async {
      final store = FakeGeoIpStore();
      final e = await upWith(store);
      final pinning = e.setExitCountry('{br}');
      await pumpEventQueue();
      store.nextDownload!.complete(null);
      await pinning;

      await e.setExitCountry('{br}');
      expect(store.downloads, hasLength(1),
          reason: 'every save calls this; a retry is a 10 MB download');

      final retry = e.restart();
      await pumpEventQueue();
      expect(runtime.startCalls, 1, reason: 'tor is up; only the pin retries');
      store.nextDownload!.complete(table);
      await retry;
      expect(runtime.appliedExitNodes, ['{br}']);
      expect(e.status, isA<TorUp>());
      await e.dispose();
    });

    test('an archived site uses a kept table and never downloads one',
        () async {
      // ARCH-006: a table downloaded for an archived site would be a trace
      // of it outside the archive.
      final store = FakeGeoIpStore();
      final e = await upWith(store);
      await e.setExitCountry('{br}', mayFetchGeoIp: false);
      expect(store.downloads, isEmpty);
      expect(runtime.appliedExitNodes, isEmpty);
      expect((e.status as TorErrored).kind, TorFailureKind.exitCountryData);
      expect(e.socksFor('site-a'), isNull, reason: 'fails closed, pin kept');
      await e.dispose();

      runtime = FakeTorRuntime();
      final stale = FakeGeoIpStore()..kept = table;
      final f = await upWith(stale,
          now: fetchedAt.add(kTorGeoIpMaxAge + const Duration(days: 1)));
      await f.setExitCountry('{br}', mayFetchGeoIp: false);
      expect(runtime.appliedGeoIpFiles, [table.path]);
      expect(stale.downloads, isEmpty, reason: 'not even a refresh');
      await f.dispose();
    });

    test('a fresh tor with no pin is left alone', () async {
      // Clearing closes every exit circuit, so a no-op clear on a cold start
      // would cut the first page loads of every Tor site.
      final store = FakeGeoIpStore();
      final e = await upWith(store);
      await e.setExitCountry(null);
      expect(runtime.appliedExitNodes, isEmpty);
      expect(e.status, isA<TorUp>());
      await e.dispose();
    });

    test('clearing a pin needs no table', () async {
      final store = FakeGeoIpStore()..kept = table;
      final e = await upWith(store);
      await e.setExitCountry('{br}');
      store.kept = null;
      await e.setExitCountry(null);
      expect(store.downloads, isEmpty);
      expect(runtime.appliedExitNodes, ['{br}', null]);
      expect(runtime.appliedGeoIpFiles.last, isNull);
      expect(e.status, isA<TorUp>());
      await e.dispose();
    });

    test('a newer pin wins over one still downloading', () async {
      final store = FakeGeoIpStore();
      final e = await upWith(store);
      final first = e.setExitCountry('{br}');
      await pumpEventQueue();
      final second = e.setExitCountry('{de}');
      store.nextDownload!.complete(table);
      await first;
      await second;

      expect(runtime.appliedExitNodes, ['{de}'],
          reason: 'the superseded pin never reaches tor');
      expect(e.exitNodes, '{de}');
      expect(e.status, isA<TorUp>());
      await e.dispose();
    });

    test('a pin tor never answers does not block the next one', () {
      fakeAsync((async) {
        final store = FakeGeoIpStore()..kept = table;
        final e = build(geoIpStore: store, clock: () => fetchedAt);
        e.acquire('site-a');
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();

        runtime.exitCountryHangs = true;
        e.setExitCountry('{br}');
        async.elapse(kTorExitPinApplyTimeout);
        expect(e.status, isA<TorErrored>(),
            reason: 'a hung control connection is a failure, not a wait');

        runtime.exitCountryHangs = false;
        e.setExitCountry('{de}');
        async.flushMicrotasks();
        expect(runtime.appliedExitNodes, ['{de}']);
        expect(e.status, isA<TorUp>());
      });
    });

    test('a change holds Tor sites before the caller could wait on it', () {
      // What lets activation stop awaiting the pin: the hold is in place
      // the moment the change is asked for, not once tor answers.
      fakeAsync((async) {
        final e = build(geoIpStore: FakeGeoIpStore()..kept = table);
        e.acquire('site-a');
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();

        runtime.exitCountryHangs = true;
        e.setExitCountry('{br}');
        expect(e.status, isA<TorBootstrapping>());
        expect(e.socksFor('site-a'), isNull);
        async.elapse(kTorExitPinApplyTimeout);
      });
    });

    test('BUG-018: a clear tor never answers fails closed, once', () {
      // The reported hang. A pin was in force, the app slept long enough
      // for iOS to reclaim the control socket, and the next site switch
      // cleared the pin: the RESETCONF went nowhere, and every later tap
      // re-sent it and waited again.
      fakeAsync((async) {
        final e = build(geoIpStore: FakeGeoIpStore()..kept = table);
        e.acquire('site-a');
        runtime.bootstrapTo(9999);
        async.flushMicrotasks();
        e.setExitCountry('{br}');
        async.flushMicrotasks();
        expect(e.status, isA<TorUp>());

        runtime.exitCountryHangs = true;
        final calls = runtime.applyCalls;
        var settled = false;
        e.setExitCountry(null).then((_) => settled = true);
        async.elapse(kTorExitPinApplyTimeout);
        expect(settled, isTrue, reason: 'the change is bounded');
        final status = e.status;
        expect(status, isA<TorErrored>());
        expect((status as TorErrored).kind, TorFailureKind.controlChannel,
            reason: 'a silent control port is not a dead country');
        expect(e.socksFor('site-a'), isNull, reason: 'fails closed');

        for (var tap = 0; tap < 3; tap++) {
          e.setExitCountry(null);
          async.flushMicrotasks();
        }
        expect(runtime.applyCalls, calls + 1,
            reason: 'a tap after the failure does not re-send and wait again');

        runtime.exitCountryHangs = false;
        e.restart();
        async.flushMicrotasks();
        expect(runtime.appliedExitNodes.last, isNull);
        expect(e.status, isA<TorUp>(), reason: 'Retry re-applies the clear');
      });
    });

    test('tor refusing the pin for want of GeoIP reads as missing data',
        () async {
      final store = FakeGeoIpStore()..kept = table;
      final e = await upWith(store);
      runtime.exitCountryError = StateError(
          'PlatformException(geoip_unavailable, Tor has no GeoIP data '
          'loaded, null, null)');
      await e.setExitCountry('{br}');
      expect((e.status as TorErrored).kind, TorFailureKind.exitCountryData);
      await e.dispose();
    });
  });

  group('TOR-024 tor outlives the app being suspended', () {
    // iOS defuncts every TCP socket a suspended app owns. tor lives on, and
    // so does its control channel (a Unix socket), but its SOCKS listener
    // is dead while tor still lists it. The listener is asked on the way
    // back, and a dead one is reopened on another port.
    final dead = <int>{};
    final asked = <int>[];
    Future<bool> probe(String host, int port) async {
      asked.add(port);
      return !dead.contains(port);
    }

    setUp(() {
      dead.clear();
      asked.clear();
    });

    test('a listener that still answers is left alone', () {
      fakeAsync((async) {
        final e = build(socksProbe: probe);
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(41337);
        async.flushMicrotasks();

        e.revive();
        async.flushMicrotasks();
        expect(asked, [41337]);
        expect(runtime.reopenCalls, 0);
        expect(e.socksFor('site-a')!.address, '127.0.0.1:41337');
      });
    });

    test('a dead listener is reopened and the sites move with it', () {
      fakeAsync((async) {
        final e = build(socksProbe: probe);
        final seen = <TorStatus>[];
        e.statusStream.listen(seen.add);
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(41337);
        async.flushMicrotasks();
        final before = e.status;

        dead.add(41337);
        e.revive();
        async.flushMicrotasks();
        expect(runtime.reopenCalls, 1);
        expect(runtime.startCalls, 1,
            reason: 'the same tor, never a second launch (BUG-013)');
        expect(e.socksFor('site-a')!.address, '127.0.0.1:45000');
        expect(torBindingChanged(before, e.status), isTrue,
            reason: 'the endpoint moved, so every Tor-bound site rebuilds');
        expect(
            seen.whereType<TorBootstrapping>().map((s) => s.tag),
            contains(kTorReopenTag),
            reason: 'sites wait while the listener is reopened rather than '
                'dial the dead one');
      });
    });

    test('a reopen that fails is reported, and Retry tries it again', () {
      fakeAsync((async) {
        final e = build(socksProbe: probe);
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(41337);
        async.flushMicrotasks();

        dead.add(41337);
        runtime.reopenError = StateError('control_unreachable');
        e.revive();
        async.flushMicrotasks();
        expect(e.status, isA<TorErrored>());
        expect(e.socksFor('site-a'), isNull,
            reason: 'the dead listener must never be handed out as up');

        runtime.reopenError = null;
        e.restart();
        async.flushMicrotasks();
        expect(runtime.reopenCalls, 2);
        expect(e.socksFor('site-a')!.address, '127.0.0.1:45000');
      });
    });

    test('a resume mid-bootstrap asks the listener tor names on coming up', () {
      // A background launch starts tor and iOS suspends it seconds later;
      // tor then finishes bootstrapping on a listener opened before that.
      fakeAsync((async) {
        final e = build(socksProbe: probe);
        final seen = <TorStatus>[];
        e.statusStream.listen(seen.add);
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.emit(const TorBootstrapping(40));
        async.flushMicrotasks();

        e.revive();
        async.flushMicrotasks();
        expect(asked, isEmpty, reason: 'there is no listener to ask yet');

        dead.add(41337);
        runtime.emit(TorUp('127.0.0.1', 41337));
        async.flushMicrotasks();
        expect(asked, [41337]);
        expect(seen.whereType<TorUp>().map((s) => s.port), [45000],
            reason: 'the dead listener is never published as up');
      });
    });

    test('an exit pin in force stays in force across a reopen', () {
      fakeAsync((async) {
        final e = build(socksProbe: probe);
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(41337);
        async.flushMicrotasks();
        e.setExitCountry('{de}');
        async.flushMicrotasks();
        expect(runtime.appliedExitNodes, ['{de}']);

        dead.add(41337);
        e.revive();
        async.flushMicrotasks();
        expect(e.socksFor('site-a')!.address, '127.0.0.1:45000');
        expect(runtime.appliedExitNodes, ['{de}'],
            reason: 'the same tor keeps its ExitNodes; nothing re-applies it');
      });
    });

    test('a bootstrap deadline slept through starts over', () {
      fakeAsync((async) {
        var now = DateTime(2026, 9, 25, 7, 25);
        final e = build(
          timeout: const Duration(seconds: 90),
          clock: () => now,
        );
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.emit(const TorBootstrapping(10));
        async.flushMicrotasks();

        // Suspended for a quarter of an hour; the timer fires on the wake.
        now = now.add(const Duration(minutes: 15));
        async.elapse(const Duration(seconds: 91));
        expect(e.status, isA<TorBootstrapping>(),
            reason: 'tor was frozen for all but a moment of that window');

        async.elapse(const Duration(seconds: 91));
        expect(e.status, isA<TorErrored>(),
            reason: 'a window tor actually had still ends in a report');
      });
    });

    test('without a probe nothing is asked', () {
      fakeAsync((async) {
        final e = build();
        e.acquire('site-a');
        async.flushMicrotasks();
        runtime.bootstrapTo(41337);
        async.flushMicrotasks();
        e.revive();
        async.flushMicrotasks();
        expect(runtime.reopenCalls, 0);
      });
    });
  });
}
