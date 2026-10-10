// Random walks over the real activation stack: taps, home, memory pressure,
// sign-ins, adds and moves, interleaved at microtask granularity, with noise
// that must change nothing it does not predict. Each walk runs twice and must
// match itself. Rerun one seed with WALK_SEED=n; explore with WALK_SEEDS=k.
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
  ),
  'mixed domains, containers': (
    hosts: _mixedHosts,
    pool: _mixedPool,
    containers: true,
  ),
  'crowd, shared jar': (hosts: _crowdHosts, pool: const [], containers: false),
  'crowd, containers': (hosts: _crowdHosts, pool: const [], containers: true),
};

final _draws = <SiteAction Function(WalkRng rng), int>{
  (r) => Tap(r.nextInt(64)): 30,
  (r) => const Settle(): 20,
  (r) => Yield(1 + r.nextInt(8)): 10,
  (r) => const GoHome(): 5,
  (r) => const Pressure(): 10,
  (r) => Login(r.nextInt(64)): 8,
  (r) => Add(r.nextInt(64)): 3,
  (r) => Move(r.nextInt(64), to: r.nextInt(64)): 4,
  (r) => const Retap(): 4,
  (r) => const Touch(): 2,
  (r) => StayPut(r.nextInt(64)): 2,
};

SiteAction _draw(WalkRng rng) => rng.pick(_draws)(rng);

/// Walks that once broke, shrunk, plus interleavings worth keeping by name.
const _regressions = <(String, List<SiteAction>)>[
  (
    'a second tap supersedes the first before it lands',
    [Tap(0), Tap(1), Settle()],
  ),
  (
    'a same-domain tap lands while the first capture runs',
    [Tap(0), Settle(), Login(0), Tap(1), Yield(2), Tap(0), Settle()],
  ),
  (
    'memory pressure inside an activation spares its target',
    [Tap(2), Settle(), Tap(3), Yield(3), Pressure(), Pressure(), Settle()],
  ),
  (
    'a move inside an activation makes it bail',
    [Tap(0), Yield(2), Move(0, to: 3), Settle(), Retap()],
  ),
  ('home inside an activation', [Tap(1), Yield(4), GoHome(), Settle()]),
  // BUG-032: the second restore snapshotted the jar the first had emptied.
  (
    'a tap back lands while the first restore refills the jar',
    [Add(29), Tap(18), Login(36), Tap(21), Yield(6), Tap(54)],
  ),
  // BUG-029: the unload removed the position it held across its capture.
  (
    'a move lands while memory pressure unloads a site',
    [
      Tap(13),
      Settle(),
      Move(13, to: 36),
      Tap(15),
      Settle(),
      Pressure(),
      Retap(),
      Pressure(),
      Move(51, to: 59),
    ],
  ),
  // BUG-029: the move superseded a switch that had unloaded the site shown.
  (
    'a move supersedes a switch after its conflict unload',
    [Tap(23), Login(42), Tap(9), Move(33, to: 22)],
  ),
  // BUG-032: two switches in flight both unloaded one site, and the second
  // capture read a jar refilled without it.
  (
    'two switches in flight both name one site to unload',
    [
      Tap(39),
      Login(19),
      Move(11, to: 38),
      Add(0),
      GoHome(),
      Tap(8),
      Tap(1),
      Tap(8),
    ],
  ),
  // BUG-029: a move just before the restore made it restore the site that
  // moved into the tapped position, beside a loaded sibling on its domain.
  ('a move before the restore leaks no cookies into the shared jar', [
    Add(0), Tap(45), Login(33), Tap(40), Settle(), GoHome(), Tap(8),
    Move(20, to: 23),
  ]),
  // CONT-003: the superseded tap of a double tap unmarked the other's
  // target, which memory pressure then evicted.
  (
    'memory pressure during a double tap spares its target',
    [
      Tap(30),
      Login(3),
      Tap(2),
      Settle(),
      Tap(30),
      Tap(8),
      Pressure(),
      Yield(2),
      Pressure(),
    ],
  ),
];

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
    test('$name: random walks hold', () async {
      await expectWalksHold(
        world: () => ActivationWorld(page),
        draw: _draw,
        seeds: walkSeeds(fixed: [for (var i = 1; i <= 30; i++) i]),
        length: 80,
      );
    }, timeout: walkTimeout);

    for (final (scenario, actions) in _regressions) {
      test('$name: $scenario', () async {
        await expectActionsHold(
          world: () => ActivationWorld(page),
          actions: actions,
        );
      });
    }
  }
}
