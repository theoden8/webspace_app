// Each mistake the model's mutants plant, planted in the code too: the
// runner takes a mutant's tables and definitions in place of the code's
// (`planted`, lib/formal_model/models.dart), so the schedules must catch it
// as TLC does, by the script named here at the bound the schedules run at,
// on a check the walk states apart from the code it checks. A mutant no
// script of the walk reaches owes why, and the owed only shrink.
//
// Apart from activation_schedules_test.dart: a planted run's traces are a
// mutant's, which formal/verify.sh must not replay against the model.
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/formal_model/checks.dart' show Mutant;
import 'package:webspace/formal_model/models.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';

import 'helpers/fake_tor_runtime.dart';
import 'helpers/walk/activation_world.dart';
import 'helpers/walk/schedules.dart';

const _oneDomain = (
  hosts: ['one.example.com', 'two.example.com', 'example.com'],
  pool: <String>[],
  containers: false,
  incognito: <String>[],
);
const _mixed = (
  hosts: ['one.example.com', 'two.example.com', 'other.test'],
  pool: <String>[],
  containers: false,
  incognito: <String>[],
);
const _mixedContainers = (
  hosts: ['one.example.com', 'two.example.com', 'other.test'],
  pool: <String>[],
  containers: true,
  incognito: <String>[],
);
const _mixedIncognito = (
  hosts: ['one.example.com', 'two.example.com', 'other.test'],
  pool: <String>[],
  containers: false,
  incognito: ['other.test'],
);

/// Sites 0 and 1 on one proxy and site 2 on another, under one
/// process-wide proxy (PROXY-008).
const WalkProxies _mismatched = (
  routes: ['p1', 'p1', 'p2'],
  exits: [null, null, null],
  scope: WalkScope.global,
  defaultSession: [],
);

/// Site 0 following the app-wide level, site 1 asking for level 2 and
/// site 2 with DNS blocking off; levels 1 and 2 to download (DNS-022).
const WalkDns _dnsSites = (siteLevels: [null, 2, kDnsLevelOff], levels: [1, 2]);

/// `All`, then sites 0 and 1, then site 2 (WEBSPACE-013).
const _spaces = [
  [0, 1],
  [2],
];

/// From launch: every site signed in last session, and the jar holding
/// what it left of sites 1 and 2; under containers, nothing.
const WalkLaunch _jarLaunch = (signedIn: [0, 1, 2], left: [1, 2]);
const WalkLaunch _boxLaunch = (signedIn: <int>[], left: <int>[]);

const _oneSignedIn = [Tap(0), Login(0)];
const _slot2Behind = [Tap(2), Login(2), Tap(0), Login(0)];
const _slot0Behind = [Tap(0), Login(0), Tap(2), Login(2)];

/// How the walk catches a planted mistake: from [setup], some schedule of
/// [script] within [preemptions] fails, and its failure names [breaks].
sealed class _Catch {
  const _Catch();
}

final class _By extends _Catch {
  const _By({
    required this.world,
    required this.setup,
    required this.script,
    required this.breaks,
    this.preemptions = 2,
  });

  /// The world, held to the mutant's declarations by the frame check.
  final ActivationWorld Function(Tables declared) world;
  final List<SiteAction> setup;
  final List<SiteAction> script;
  final String breaks;
  final int preemptions;
}

/// No script of the walk reaches the mistake yet: [why].
final class _Owed extends _Catch {
  const _Owed(this.why);
  final String why;
}

_Catch _catching(Mutant m) => switch (m) {
  Mutant.recapture => _By(
    world: (d) => ActivationWorld(_mixed, declared: d),
    setup: _slot0Behind,
    script: const [Pressure(), Pressure(), Tap(1)],
    breaks: 'walk-0 lost cookies its page set, while unloaded',
  ),
  Mutant.staleplan => _By(
    world: (d) => ActivationWorld(_oneDomain, declared: d),
    setup: _oneSignedIn,
    script: const [Tap(1), Tap(0)],
    breaks: _disposedLive,
  ),
  Mutant.noretry => _By(
    world: (d) => ActivationWorld(_mixed, declared: d),
    setup: _slot2Behind,
    script: const [Pressure(), Pressure(), Tap(2)],
    breaks: _disposedLive,
  ),
  Mutant.tierearly => _By(
    world: (d) => ActivationWorld(_oneDomain, declared: d),
    setup: _oneSignedIn,
    script: const [Tap(1), Tap(0)],
    breaks: 'a loaded site is at savedForRestore',
  ),
  Mutant.markerbytarget => _By(
    world: (d) => ActivationWorld(_mixedContainers, declared: d),
    setup: _slot2Behind,
    script: const [Tap(2), Tap(2), Pressure(), Pressure()],
    breaks: 'memory pressure unloaded walk-2 while its activation ran',
  ),
  Mutant.incognitonuked => _By(
    world: (d) => ActivationWorld(_mixedIncognito, declared: d),
    setup: _slot2Behind,
    script: const [Tap(0)],
    breaks: 'walk-2 lost cookies its page set, while loaded',
  ),
  Mutant.nukeignored => _By(
    world: (d) => ActivationWorld(_mixed, declared: d),
    setup: const [..._oneSignedIn, Fails(Fault.jarClear)],
    script: const [Tap(1)],
    breaks: "the jar holds another site's cookies under loaded",
  ),
  Mutant.preloadbare => _By(
    world: (d) => ActivationWorld(_mixed, launch: _jarLaunch, declared: d),
    setup: const [],
    script: const [Preload(0)],
    breaks: 'walk-0 lost cookies its page set, while loaded',
  ),
  Mutant.preloadmismatch => _By(
    world: (d) => ActivationWorld(
      _mixed,
      launch: _jarLaunch,
      proxies: _mismatched,
      declared: d,
    ),
    setup: const [],
    script: const [Preload(0), Preload(2)],
    breaks: _twoRoutes,
  ),
  Mutant.nestedonce => _By(
    world: (d) => _nestedWorld(declared: d),
    setup: const [],
    script: const [Tap(0), OpenNested(2), Preload(1)],
    breaks: 'a nested screen went up beside a site on another route',
  ),
  Mutant.preloadunchecked => _By(
    world: (d) => _nestedWorld(declared: d),
    setup: const [],
    script: const [OpenNested(2), Preload(1)],
    breaks: _twoRoutes,
    preemptions: 3,
  ),
  Mutant.wakeunchecked => _By(
    world: (d) => _wakeWorld(declared: d, nestedOpens: false),
    setup: const [],
    script: const [Background(), Wake()],
    breaks: 'the process-wide proxy moved under headless',
  ),
  Mutant.wakebesidetap => _By(
    world: (d) => _wakeWorld(declared: d, nestedOpens: false),
    setup: const [],
    script: const [Tap(2), Background(), Wake()],
    breaks: _twoRoutes,
    preemptions: 3,
  ),
  Mutant.wakebesidenested => _By(
    world: (d) => _wakeWorld(declared: d, nestedOpens: true),
    setup: const [],
    script: const [OpenNested(2), Background(), Wake()],
    breaks: 'a nested open unloads what its printed rules name',
  ),
  Mutant.nohome => _By(
    world: (d) => ActivationWorld(
      _mixedContainers,
      deletes: true,
      proxies: _mismatched,
      declared: d,
    ),
    setup: const [Tap(0), Tap(1)],
    script: const [Tap(2), Delete()],
    breaks: _screenUnloaded,
  ),
  Mutant.deletenoframe => _By(
    world: (d) => ActivationWorld(_mixedContainers, deletes: true, declared: d),
    setup: const [Tap(0)],
    script: const [Delete()],
    breaks: _offTheList,
  ),
  Mutant.closenoframe => _By(
    world: (d) =>
        ActivationWorld(_mixedContainers, archived: true, declared: d),
    setup: const [Tap(2), ArchiveSite(2), Tap(0)],
    script: const [CloseArchive()],
    breaks: _offTheList,
  ),
  Mutant.noreopen => _By(
    world: (d) => ActivationWorld(
      _mixedContainers,
      proxies: _mismatched,
      rehosts: true,
      declared: d,
    ),
    setup: const [Tap(0), OpenTab(0, tab: 1)],
    script: const [Reroute(), OpenTab(0, tab: 0)],
    breaks: _screenUnloaded,
  ),
  Mutant.rerouteinplace => _By(
    world: (d) => ActivationWorld(
      _mixedContainers,
      proxies: _mismatched,
      rehosts: true,
      declared: d,
    ),
    setup: const [Tap(0), OpenTab(0, tab: 1), Tap(1)],
    script: const [Reroute()],
    breaks: 'the process-wide proxy moved under webview',
  ),
  Mutant.landinplace => _By(
    world: (d) => ActivationWorld(_mixedContainers, tabbed: true, declared: d),
    setup: const [Tap(0), OpenTab(0, tab: 1)],
    script: const [HomeLand(0)],
    breaks: "'s webview is built for tab",
  ),
  Mutant.takeany => _By(
    world: (d) => ActivationWorld(_mixed, tabbed: true, declared: d),
    setup: const [Tap(0), Login(0), Tap(1)],
    script: const [Tap(0), CloseTab(0, tab: 0)],
    breaks: "webview shows another tab's history",
  ),
  Mutant.captureatreply => const _Owed(
    "the capture's key is the binding's own (NavCapture), which `Capture` "
    'describes as a write of `file` the platform holds: planting it changes '
    'no code',
  ),
  Mutant.preloadunbound => const _Owed(
    "the frame is the walk's own (`_buildWebViews`), which `TabVars.framed` "
    'describes as writes of `built`, `hist` and `queued` the platform holds: '
    'planting it changes no code',
  ),
  Mutant.foldbeforelevel => _By(
    world: (d) => ActivationWorld(_mixed, dns: _dnsSites, declared: d),
    setup: const [Tap(0)],
    script: const [DnsDownload(0)],
    breaks: 'where its site resolves to',
  ),
  Mutant.pointerearly => _By(
    world: (d) => ActivationWorld(_mixed, tabbed: true, declared: d),
    setup: const [Tap(0)],
    script: const [OpenTab(0, tab: 1)],
    breaks: 'while its active tab is',
  ),
  Mutant.spaceold => _By(
    world: (d) => ActivationWorld(_mixed, spaces: _spaces, declared: d),
    setup: const [],
    script: const [Tap(2), SwitchWebspace(1)],
    breaks: 'came on screen while a webspace switch that stopped showing it '
        'stood',
  ),
};

const _disposedLive =
    "an unload disposed the site on screen or the live activation's target";
const _twoRoutes = 'two running sites in one proxy scope run different routes';
const _screenUnloaded = 'the site on screen is not loaded';
const _offTheList =
    'a site off the list is still loaded, on screen, mounted or on disk';

ActivationWorld _nestedWorld({required Tables declared}) => ActivationWorld(
  _mixedContainers,
  launch: _boxLaunch,
  proxies: _mismatched,
  nestedOpens: true,
  declared: declared,
);

ActivationWorld _wakeWorld({
  required Tables declared,
  required bool nestedOpens,
}) => ActivationWorld(
  _mixedContainers,
  launch: _boxLaunch,
  proxies: _mismatched,
  nestedOpens: nestedOpens,
  wakes: true,
  declared: declared,
);

/// The mutants no script reaches yet; one more fails, one fewer is to be
/// written down here.
const _owedAtMost = 2;

void main() {
  setUpAll(
    () => TorService.overrideEngine(
      TorEngine(
        runtime: FakeTorRuntime(isAvailable: false),
        sessionSecret: 'walk',
      ),
    ),
  );
  // A planted mistake breaks its run mid-claim; the next world starts on a
  // rule with nothing under way.
  tearDown(ProcessRoute.instance.abandonClaimsForTest);

  for (final m in Mutant.values) {
    switch (_catching(m)) {
      case _By(:final world, :final setup, :final script, :final breaks,
          :final preemptions):
        Future<ScheduleSearch> search({required Tables declared}) =>
            expectEveryScheduleHolds(
              world: () => world(declared),
              setup: setup,
              script: script,
              preemptions: preemptions,
              commutes: null,
            );
        test('${m.name}: the code holds without it', () async {
          await search(declared: tables);
        }, timeout: Timeout.none);
        test('${m.name}: planted in the code, $script breaks "$breaks"',
            () async {
          await expectLater(
            planted(m).run(() => search(declared: mutated(m))),
            throwsA(
              isA<TestFailure>().having(
                (e) => e.message,
                'message',
                contains(breaks),
              ),
            ),
          );
        }, timeout: Timeout.none);
      case _Owed(:final why):
        test('${m.name}: planted in the code', () {}, skip: why);
    }
  }

  test('the mutants no script reaches only shrink', () {
    final owed = [
      for (final m in Mutant.values)
        if (_catching(m) is _Owed) m.name,
    ];
    expect(owed.length, lessThanOrEqualTo(_owedAtMost), reason: '$owed');
  });
}
