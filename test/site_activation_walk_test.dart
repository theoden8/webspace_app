// Random walks over the real activation stack: taps, home, memory pressure,
// preloads, sign-ins, adds and moves, landing between platform replies the walk
// releases one at a time, as input lands between events, with noise that
// must change nothing it does not predict. Each walk runs twice and must
// match itself. Rerun one seed with WALK_SEED=n; explore with WALK_SEEDS=k.
// The interleavings within a small bound are enumerated whole in
// activation_schedules_test.dart, which also keeps the bugs found here.
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';

import 'helpers/fake_tor_runtime.dart';
import 'helpers/walk/activation_world.dart';
import 'helpers/walk/walk_rng.dart';
import 'helpers/walk/walk_runner.dart';

/// A few sites per base domain, so the shared jar has conflicts to resolve.
const _mixedHosts = [
  'mail.example.com',
  'docs.example.com',
  'example.org',
  'news.example.net',
  'shop.example.net',
];

const _mixedPool = ['example.com', 'wiki.example.org', 'other.test'];

/// More distinct domains than `kMaxLoadedSites`, so the cap evicts, and more
/// than `kMaxResidentSites`, so activations clear caches.
final _crowdHosts = [for (var i = 0; i < 22; i++) 'site$i.test'];

final _pages = <String, WalkPage>{
  'mixed domains, shared jar': (
    hosts: _mixedHosts,
    pool: _mixedPool,
    containers: false,
    incognito: <String>[],
  ),
  'mixed domains, containers': (
    hosts: _mixedHosts,
    pool: _mixedPool,
    containers: true,
    incognito: <String>[],
  ),
  'crowd, shared jar': (
    hosts: _crowdHosts,
    pool: const [],
    containers: false,
    incognito: <String>[],
  ),
  'crowd, containers': (
    hosts: _crowdHosts,
    pool: const [],
    containers: true,
    incognito: <String>[],
  ),
};

final _draws = <SiteAction Function(WalkRng rng), int>{
  (r) => Tap(r.nextInt(64)): 30,
  (r) => const Settle(): 20,
  (r) => Reply(r.nextInt(4)): 30,
  (r) => const GoHome(): 5,
  (r) => const Pressure(): 10,
  (r) => Preload(r.nextInt(64)): 6,
  (r) => Login(r.nextInt(64)): 8,
  (r) => Add(r.nextInt(64)): 3,
  (r) => Move(r.nextInt(64), to: r.nextInt(64)): 4,
  (r) => const Retap(): 4,
  (r) => const Touch(): 2,
  (r) => StayPut(r.nextInt(64)): 2,
};

SiteAction _draw(WalkRng rng) => rng.pick(_draws)(rng);

/// The same, with webspaces chosen on the list (WEBSPACE-013).
final _spaceDraws = <SiteAction Function(WalkRng rng), int>{
  ..._draws,
  (r) => SwitchWebspace(r.nextInt(3)): 8,
};

SiteAction _spaceDraw(WalkRng rng) => rng.pick(_spaceDraws)(rng);

void main() {
  setUpAll(
    () => TorService.overrideEngine(
      TorEngine(
        runtime: FakeTorRuntime(isAvailable: false),
        sessionSecret: 'walk',
      ),
    ),
  );

  for (final MapEntry(key: name, value: page) in _pages.entries) {
    test('$name: random walks hold (NAV-013)', () async {
      await expectWalksHold(
        world: () => ActivationWorld(page),
        draw: _draw,
        seeds: walkSeeds(fixed: [for (var i = 1; i <= 30; i++) i]),
        length: 80,
      );
    }, timeout: walkTimeout);
  }

  // The pressure itself can blank the site on screen, which the eviction
  // never touches: a dead renderer is probed, then a live surface nudged.
  test('pressure that evicts probes then nudges the site on screen (PAUSE-019)',
      () async {
    final world = ActivationWorld(_pages['crowd, containers']!);
    for (final i in [1, 2, 0]) {
      await world.apply(Tap(i));
      await world.settle();
    }
    expect(world.sites.loaded, hasLength(3), reason: 'a victim to promote');
    world.recoveries.clear();
    await world.apply(const Pressure());
    await world.settle();
    expect(world.recoveries, [
      'probe ${world.sites.shown!.siteId} memory-pressure',
      'nudge memory-pressure',
    ]);
  });

  // Every flow holds its sites, not rows, so a reorder has nothing to
  // supersede: the switch it lands in finishes on the site it was opening.
  for (final name in ['mixed domains, shared jar', 'mixed domains, containers']) {
    test('$name: a row move mid-switch lets the switch finish (LAZY-007)',
        () async {
      final world = ActivationWorld(_pages[name]!);
      await world.apply(const Tap(0));
      await world.settle();
      await world.apply(const Tap(2));
      final tapped = world.sites.activating?.target;
      expect(tapped, isNotNull, reason: 'the switch is still opening');
      await world.apply(const Move(0, to: 2));
      await world.settle();
      expect(world.sites.shown, same(tapped));
      expect(world.sites.loaded, contains(tapped));
    });
  }

  // A webspace chosen while a tapped site opens supersedes the opening, so
  // the list stays, and the site goes on loading behind it.
  for (final name in ['mixed domains, shared jar', 'mixed domains, containers']) {
    test('$name: a switch keeps loading the site a tap was opening '
        '(WEBSPACE-013)', () async {
      final world = ActivationWorld(
        _pages[name]!,
        spaces: const [
          [0, 1, 2],
          [2, 3, 4],
        ],
      );
      await world.apply(const Tap(0));
      final tapped = world.sites.activating?.target;
      expect(tapped, isNotNull, reason: 'the tap is still opening');
      await world.apply(const SwitchWebspace(2));
      await world.settle();
      expect(world.sites.shown, isNull, reason: 'the list stays');
      expect(world.sites.loaded, contains(tapped));
    });
  }

  // With only the site on screen loaded nothing is evicted, and the
  // pressure can still blank it.
  test('pressure that evicts nothing still probes then nudges the site on '
      'screen (PAUSE-019)', () async {
    final world = ActivationWorld(_pages['crowd, containers']!);
    await world.apply(const Tap(0));
    await world.settle();
    expect(world.sites.loaded, hasLength(1), reason: 'nothing to evict');
    world.recoveries.clear();
    await world.apply(const Pressure());
    await world.settle();
    expect(world.sites.loaded, hasLength(1));
    expect(world.recoveries, [
      'probe ${world.sites.shown!.siteId} memory-pressure',
      'nudge memory-pressure',
    ]);
  });

  for (final name in ['mixed domains, shared jar', 'mixed domains, containers']) {
    test('$name, webspaces: random walks hold (WEBSPACE-013)', () async {
      await expectWalksHold(
        world: () => ActivationWorld(
          _pages[name]!,
          spaces: const [
            [0, 1, 2],
            [2, 3, 4],
          ],
        ),
        draw: _spaceDraw,
        seeds: walkSeeds(fixed: [for (var i = 1; i <= 30; i++) i]),
        length: 80,
      );
    }, timeout: walkTimeout);
  }

  // From launch: the last session signed every site in and left the first
  // two of each base domain's cookies in the shared jar.
  test('mixed domains, shared jar, from launch: random walks hold', () async {
    await expectWalksHold(
      world: () => ActivationWorld(
        _pages['mixed domains, shared jar']!,
        launch: (signedIn: const [0, 1, 2, 3, 4], left: const [1, 2, 4]),
      ),
      draw: _draw,
      seeds: walkSeeds(fixed: [for (var i = 1; i <= 30; i++) i]),
      length: 80,
    );
  }, timeout: walkTimeout);
}
