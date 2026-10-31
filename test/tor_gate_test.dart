// Tor is reachable wherever the platform has the runtime (TOR-007); nothing
// else gates it. The gate lives on TorService, not on the runtime or the
// engine: those answer the narrower "does this build have a tor to talk to",
// which the engine's own tests exercise against a fake.


import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
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
    DeveloperModeService.instance.debugSet(on: false);
  });

  test('developer mode does not gate Tor', () async {
    DeveloperModeService.instance.debugSet(on: false);
    expect(TorService.instance.isAvailable, isTrue);
    await TorService.instance.syncHolders({TorSiteHolder(SiteId('site-a'))});
    expect(runtime.startCalls, 1,
        reason: 'a site pinned to Tor starts it with developer mode off');
  });

  test('turning developer mode off keeps Tor sites routed', () async {
    DeveloperModeService.instance.debugSet(on: true);
    await TorService.instance.syncHolders({TorSiteHolder(SiteId('site-a'))});
    runtime.emit(const TorUp('127.0.0.1', port: 41337));
    await Future<void>.delayed(Duration.zero);

    DeveloperModeService.instance.debugSet(on: false);
    expect(TorService.instance.socksFor(siteId: SiteId('site-a')), isNotNull);
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
      await TorService.instance.maybeStart(TorSiteHolder(SiteId('site-a')));
      await TorService.instance.syncHolders({TorSiteHolder(SiteId('site-a')), TorSiteHolder(SiteId('site-b'))});
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
      expect(TorService.instance.socksFor(siteId: SiteId('site-a')), isNull);
    });
  });

  test('the SOCKS settings carry the isolation tag', () async {
    await TorService.instance.syncHolders({TorSiteHolder(SiteId('site-a'))});
    runtime.emit(const TorUp('127.0.0.1', port: 41337));
    await Future<void>.delayed(Duration.zero);

    final resolved = TorService.instance.socksFor(siteId: SiteId('site-a'))!;
    expect(resolved.type, ProxyType.SOCKS5);
    expect(resolved.username, 'site-a');
  });

  // TOR-027: the Built-in Tor experiment on Linux takes effect as its
  // switch moves, not at the next launch. The service reads the same rule
  // the running app does, for Linux.
  group('TOR-027 the Built-in Tor experiment, followed as it moves', () {
    final mail = TorSiteHolder(SiteId('mail'));

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    void onLinux({bool available = true}) {
      runtime = FakeTorRuntime(isAvailable: available);
      TorService.overrideEngine(
        TorEngine(runtime: runtime, sessionSecret: 'secret'),
        builtInOffered: () =>
            TorService.builtInOfferedNow(platform: TargetPlatform.linux),
      );
    }

    setUp(() async {
      await TorService.reset();
      await runtime.dispose();
      DeveloperModeService.instance.debugSet(on: true);
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.linuxTor, on: false);
    });

    tearDown(() => ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.linuxTor, on: false));

    test('off, a site set to Tor is blocked and starts nothing', () async {
      onLinux();
      expect(TorService.instance.isAvailable, isFalse);
      expect(TorService.instance.offered, isFalse,
          reason: 'the pickers do not offer TOR');
      await TorService.instance.syncHolders({mail});
      expect(runtime.startCalls, 0);
      expect(TorService.instance.socksFor(siteId: mail.siteId), isNull);
    });

    test('switched on, what wanted Tor is held, with no relaunch', () async {
      onLinux();
      await TorService.instance.syncHolders({mail});
      await TorService.instance.setExitCountry('{de}');
      var announced = 0;
      final sub = TorService.instance.availabilityChanges
          .listen((_) => announced++);
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.linuxTor, on: true);
      await settle();
      expect(TorService.instance.isAvailable, isTrue);
      expect(TorService.instance.offered, isTrue);
      expect(announced, 1,
          reason: 'the page settles its Tor sites and their pins on it');
      expect(runtime.startCalls, 1, reason: 'the held site starts tor');
      runtime.emit(const TorUp('127.0.0.1', port: 41337));
      await settle();
      expect(runtime.appliedExitNodes, contains('{de}'),
          reason: 'the pin asked for while off is in force (TOR-014)');
      expect(TorService.instance.socksFor(siteId: mail.siteId), isNotNull);
      await sub.cancel();
    });

    test('switched off again, every Tor site is blocked and told so',
        () async {
      onLinux();
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.linuxTor, on: true);
      await settle();
      await TorService.instance.syncHolders({mail});
      runtime.emit(const TorUp('127.0.0.1', port: 41337));
      await settle();
      final seen = <TorStatus>[];
      final sub = TorService.instance.statusStream.listen(seen.add);

      DeveloperModeService.instance.debugSet(on: false);
      await settle();
      expect(TorService.instance.isAvailable, isFalse,
          reason: 'developer mode off takes its experiments with it');
      expect(seen.last, isA<TorStopped>(),
          reason: 'stopped, so every Tor-bound site rebinds and blocks');
      expect(TorService.instance.status, isA<TorStopped>());
      expect(TorService.instance.holders, isEmpty);
      expect(TorService.instance.socksFor(siteId: mail.siteId), isNull);
      expect(runtime.stopCalls, 0, reason: 'tor is never stopped (TOR-020)');

      runtime.emit(const TorUp('127.0.0.1', port: 41338));
      await settle();
      expect(seen.last, isA<TorStopped>(),
          reason: 'what tor says no longer reaches the app');
      await sub.cancel();
    });

    test('on with no tor to start, TOR is offered and says to install one',
        () async {
      onLinux(available: false);
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.linuxTor, on: true);
      await settle();
      expect(TorService.instance.offered, isTrue);
      expect(TorService.instance.isAvailable, isFalse);
      expect(TorService.instance.builtInOffered, isTrue,
          reason: 'what the site screen reads to say install tor');
      await TorService.instance.syncHolders({mail});
      expect(runtime.startCalls, 0);
    });
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
        const TorUp('127.0.0.1', port: 41337),
      ]) {
        expect(torGateFor(status: s, hasNativeTor: true), TorGate.working);
      }
    });
  });
}
