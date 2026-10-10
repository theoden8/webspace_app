// The real activation stack walked in formal/kernel.tla's alphabet, three
// sites as in kernel.cfg, every settled step written in the kernel's
// observable variables. formal/trace/check_walk.sh holds the steps against
// TLC's state graph of the kernel, in both directions; this file runs the
// walks and their Dart-side invariants on their own.
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_tor_runtime.dart';
import 'helpers/walk/activation_world.dart';
import 'helpers/walk/model_trace.dart';
import 'helpers/walk/walk_rng.dart';
import 'helpers/walk/walk_runner.dart';

/// Distinct domains reach every loaded set; one shared base domain makes
/// each activation unload the site it replaces; a mix does both.
final _pages = <String, WalkPage>{
  'distinct domains, shared jar': (
    hosts: const ['a.test', 'b.test', 'c.test'],
    pool: const [],
    containers: false,
  ),
  'one base domain, shared jar': (
    hosts: const ['one.example.com', 'two.example.com', 'example.com'],
    pool: const [],
    containers: false,
  ),
  'mixed, shared jar': (
    hosts: const ['one.example.com', 'two.example.com', 'other.test'],
    pool: const [],
    containers: false,
  ),
  'distinct domains, containers': (
    hosts: const ['a.test', 'b.test', 'c.test'],
    pool: const [],
    containers: true,
  ),
  'one base domain, containers': (
    hosts: const ['one.example.com', 'two.example.com', 'example.com'],
    pool: const [],
    containers: true,
  ),
};

final _draws = <SiteAction Function(WalkRng rng), int>{
  (r) => Tap(r.nextInt(3)): 50,
  (r) => const Pressure(): 30,
  (r) => Login(r.nextInt(3)): 10,
  (r) => const Retap(): 5,
  (r) => const Touch(): 3,
  (r) => StayPut(r.nextInt(3)): 2,
};

SiteAction _draw(WalkRng rng) => rng.pick(_draws)(rng);

/// The kernel's actions each Dart action stands for. An activation unloads
/// what it conflicts with after the kernel's `Activate` (a conflict can be
/// the site it replaces, which `Evict` may take once it is not on screen);
/// memory pressure unloads one site or only clears a cache.
String _path(SiteAction action) => switch (action) {
  Tap() || Retap() => 'Activate Evict*',
  Pressure() => 'Evict?',
  Login() || Touch() || StayPut() => '',
  GoHome() ||
  Yield() ||
  Settle() ||
  Add() ||
  Move() => throw ArgumentError('$action is outside the kernel walk'),
};

final _trace = ModelTrace(module: 'kernel', config: 'kernel.cfg');

const _init = {'currentIndex': '1', 'loaded': '{1}', 'jarOwner': '1'};

/// [ActivationWorld] seen through the kernel: positions count from 1, and
/// `jarOwner` is read off the jar, not assumed.
final class KernelWorld implements WalkWorld<SiteAction> {
  KernelWorld(WalkPage page) : inner = ActivationWorld(page);

  final ActivationWorld inner;
  bool _started = false;

  @override
  Future<void> apply(SiteAction action) async {
    if (!_started) {
      _started = true;
      await inner.apply(const Tap(0));
      await inner.settle();
      expect(_state(), _init, reason: 'the first activation lands on Init');
    }
    final from = _state();
    final shownBefore = inner.sites.current;
    await inner.apply(action);
    await inner.settle();
    // TLC's labels carry no parameters, so which site an Activate named is
    // checked here.
    final aimed = switch (action) {
      Tap(:final slot) => slot % inner.sites.models.length,
      Retap() => shownBefore,
      _ => null,
    };
    if (aimed != null) {
      expect(inner.sites.current, aimed, reason: '$action landed elsewhere');
    }
    _trace.step(from: from, path: _path(action), to: _state());
  }

  @override
  Future<void> settle() => inner.settle();

  @override
  String snapshot() => inner.snapshot();

  Map<String, String> _state() {
    final sites = inner.sites;
    final current = sites.current;
    expect(
      current,
      isNotNull,
      reason: 'the kernel always has a site on screen',
    );
    return {
      'currentIndex': '${current! + 1}',
      'loaded': tlaIntSet([for (final i in sites.loaded) i + 1]),
      'jarOwner': '${_jarOwner(current)}',
    };
  }

  /// The position, from 1, of the site whose cookies the jar holds for the
  /// site on screen: its own when every cookie on its base domain is its
  /// own (none counts), another's when they are all one other site's, and 0,
  /// a value the kernel never takes, for anything else.
  int _jarOwner(int current) {
    final sites = inner.sites;
    final shown = sites.models[current];
    if (inner.page.containers) {
      return inner.native.containers.containsKey(shown.siteId)
          ? current + 1
          : 0;
    }
    final base = getBaseDomain(shown.initUrl);
    final owners = {
      for (final c in inner.jar.all)
        if (cookieMatchesBaseDomain(c, baseDomain: base)) c.value,
    }..remove(shown.siteId);
    if (owners.isEmpty) return current + 1;
    if (owners.length > 1) return 0;
    return sites.models.indexWhere((m) => m.siteId == owners.single) + 1;
  }
}

void main() {
  setUpAll(
    () => TorService.overrideEngine(
      TorEngine(
        runtime: FakeTorRuntime(isAvailable: false),
        sessionSecret: 'walk',
      ),
    ),
  );
  tearDownAll(_trace.writeIfAsked);

  for (final MapEntry(key: name, value: page) in _pages.entries) {
    test('$name: walks in the kernel alphabet hold', () async {
      await expectWalksHold(
        world: () => KernelWorld(page),
        draw: _draw,
        seeds: walkSeeds(fixed: [for (var i = 1; i <= 40; i++) i]),
        length: 40,
      );
    }, timeout: walkTimeout);
  }
}
