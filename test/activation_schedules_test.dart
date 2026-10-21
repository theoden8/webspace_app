// Every interleaving of the real activation stack within a bound: for each
// page, each starting state and each script of user and OS actions, every
// schedule of platform replies and action arrivals with at most two
// preemptions (schedules.dart says what counts), less those that only swap
// two steps whose footprints share no variable (tableCommutes), which end
// where the schedule kept does. The random walks sample past the bound;
// the named scripts below, each a bug the code once had, run at the bound
// that found them. SCHEDULE_LENGTH and SCHEDULE_PREEMPTIONS widen the bound
// locally; SCHEDULE_REDUCTION=off runs every schedule within one
// preemption, none pruned, as the search did before, and SCHEDULE_STATS=1
// prints how many schedules ran.
//
// CI runs this file once, sharded, in formal/verify.sh's schedules stage;
// the whole-suite runs exclude the tag (test/js/schedules_run_once.test.js).
@Tags(['schedules'])
library;

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:webspace/formal_model/models.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';

import 'helpers/fake_tor_runtime.dart';
import 'helpers/walk/activation_world.dart';
import 'helpers/walk/schedules.dart';
import 'helpers/walk/shards.dart';
import 'helpers/walk/step_traces.dart';
import 'helpers/walk/unmodeled_meets.dart';
import 'helpers/walk/table_commutes.dart';

/// Three sites as in formal/kernel.cfg: all on one base domain, so each
/// switch unloads the site it replaces; or two sharing one and a third apart.
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

/// [_mixed] with its third site incognito, on a base domain of its own.
const _mixedIncognito = (
  hosts: ['one.example.com', 'two.example.com', 'other.test'],
  pool: <String>[],
  containers: false,
  incognito: ['other.test'],
);

/// Three sites on three base domains, so all three stay loaded together
/// on the shared jar.
const _threeBases = (
  hosts: ['one.example.com', 'other.test', 'third.example.org'],
  pool: <String>[],
  containers: false,
  incognito: <String>[],
);

const _pages = <String, WalkPage>{
  'one base domain, shared jar': _oneDomain,
  'mixed, shared jar': _mixed,
  'mixed, containers': _mixedContainers,
};

/// Where each script starts: one site signed in on screen, or a second
/// signed in and loaded behind it, on a base domain of its own or on the one
/// slot 1 shares.
const _oneSignedIn = [Tap(0), Login(0)];
const _slot2Behind = [Tap(2), Login(2), Tap(0), Login(0)];
const _slot0Behind = [Tap(0), Login(0), Tap(2), Login(2)];

const _setups = <String, List<SiteAction>>{
  'one site signed in': _oneSignedIn,
  'slot 2 signed in behind': _slot2Behind,
  'slot 0 signed in behind': _slot0Behind,
};

/// From launch: every site signed in last session, and the jar holding what
/// it left of slot 1, which shares slot 0's base domain, and of slot 2.
/// Under containers the jar is no site's, so nothing is left in it.
const _launches = <String, ({WalkPage page, WalkLaunch launch})>{
  'mixed, shared jar, from launch': (
    page: _mixed,
    launch: (signedIn: [0, 1, 2], left: [1, 2]),
  ),
  'mixed, containers, from launch': (
    page: _mixedContainers,
    launch: (signedIn: <int>[], left: <int>[]),
  ),
};

/// The proxies the launch sweeps run under: sites 0 and 1 on one proxy and
/// site 2 on another under one process-global proxy (PROXY-008); the same
/// routes under the router, with sites 0 and 2 in its default session
/// (PROXY-013, LIR-024); and sites 0 and 1 on Tor with different exits
/// beside a direct site 2, a proxy per session (TOR-025).
const _proxied = <String, WalkProxies>{
  'mismatched proxies': (
    routes: ['p1', 'p1', 'p2'],
    exits: [null, null, null],
    scope: WalkScope.global,
    defaultSession: [],
  ),
  'the router': (
    routes: ['p1', 'p1', 'p2'],
    exits: [null, null, null],
    scope: WalkScope.router,
    defaultSession: [0, 2],
  ),
  'two Tor exits': (
    routes: [null, null, null],
    exits: ['de', 'fr', null],
    scope: WalkScope.session,
    defaultSession: [],
  ),
};

const _launchAlphabet = <SiteAction>[
  Preload(0),
  Preload(1),
  Preload(2),
  Tap(0),
  Tap(2),
  GoHome(),
  Pressure(),
  Move(0, to: 2),
];

/// The inputs around a nested open: a link opening a site whose route or
/// Tor exit differs from the loaded ones', beside the launch's preloads, a
/// tap and memory pressure (LIR-011, PROXY-008).
const _nestedAlphabet = <SiteAction>[
  Preload(0),
  Preload(1),
  Tap(0),
  OpenNested(1),
  OpenNested(2),
  Pressure(),
];

/// The inputs around a background wake (NOTIF-016): a tap that may still
/// be in flight as the app leaves the screen, a launch preload, the wake
/// that checks the notification sites headless, memory pressure, and the
/// app's return.
const _wakeAlphabet = <SiteAction>[
  Tap(2),
  Preload(0),
  Background(),
  Wake(),
  Pressure(),
  Foreground(),
];

/// A link opening the site on another route beside a background wake
/// (BUG-037): the app may leave the screen while the open waits on the
/// proxy, and the wake's checks ask the rule beside an open in flight.
const _nestedWakeAlphabet = <SiteAction>[
  OpenNested(2),
  Background(),
  Wake(),
  Foreground(),
  Tap(0),
];

/// DNS (DNS-022): the first site follows the app-wide level, the second
/// asks for level 2 and the third has DNS blocking off.
const WalkDns _dnsSites = (siteLevels: [null, 2, kDnsLevelOff], levels: [1, 2]);

/// The inputs around a DNS download: level 1 as the app-wide level, level
/// 2 for the site that asks for it, the clear, and the taps and pressure
/// that build and drop the views they reach.
const _dnsAlphabet = <SiteAction>[
  Tap(0),
  Tap(1),
  DnsDownload(0),
  DnsAddLevel(1),
  DnsClear(),
  Pressure(),
];

/// A wake the model broke before the code ran it, at three preemptions,
/// under the mismatched proxies (BUG-037).
const _wakeRegressions = <String, List<SiteAction>>{
  'a wake checks a site beside a tap in flight, whose plan ran before it':
      [Tap(2), Background(), Wake()],
};

/// A nested open the code once broke (BUG-037), at three preemptions, under
/// the mismatched proxies: the preload's commit beside a screen needs the
/// open's move and the preload's two replies to cross.
const _nestedRegressions = <String, List<SiteAction>>{
  'a tap in flight commits beside a nested screen, which unloaded the '
      'site on screen': [Tap(0), OpenNested(2)],
  'a site loaded during a nested open stays beside its screen': [
    Tap(0),
    OpenNested(2),
    Preload(1),
  ],
  'a tap during a nested open has its site disposed': [
    Preload(0),
    OpenNested(2),
    Tap(0),
  ],
  'a preload commits beside a nested screen that went up since its input': [
    OpenNested(2),
    Preload(1),
  ],
  'a nested open superseded after its proxy moved keeps its claim': [
    OpenNested(2),
    Preload(1),
    Tap(0),
  ],
};

/// A launch the code once broke, at two preemptions.
const _launchRegressions = <String, List<SiteAction>>{
  'a notification site loaded over what the last session left (NOTIF-017)': [
    Preload(0),
    Preload(2),
  ],
  'the launch clear empties a session a restore put back (ISO-012)': [
    Preload(2),
    Tap(0),
    Preload(1),
  ],
  'a tap supersedes a preload under way': [Preload(0), Tap(2), Preload(1)],
};

/// A script the code once broke, with the page and setup it broke from,
/// each run at two preemptions.
const _regressions =
    <
      String,
      ({WalkPage page, List<SiteAction> setup, List<SiteAction> script})
    >{
      // Every switch on the shared jar empties it, and the restore set back
      // only the sites whose share it saved, so a loaded incognito site was
      // signed out by any other site's activation (INC-001).
      'a switch keeps a loaded incognito site\'s session (INC-001)': (
        page: _mixedIncognito,
        setup: _slot2Behind,
        script: [Tap(1)],
      ),
      'an unloaded incognito site leaves nothing in its storage (INC-001)': (
        page: _mixedIncognito,
        setup: _slot2Behind,
        script: [Pressure(), Pressure(), Tap(1)],
      ),
      'an incognito target has nothing to restore (INC-001)': (
        page: _mixedIncognito,
        setup: _oneSignedIn,
        script: [Tap(2)],
      ),
      // Each loaded site's share goes back after the target's, one site at
      // a time (ISO-003).
      'a restore sets back the share of every other loaded site': (
        page: _threeBases,
        setup: [
          Tap(0),
          Login(0),
          Tap(1),
          Login(1),
          Tap(2),
          Login(2),
        ],
        script: [Tap(0)],
      ),
      // A home reset's unload picks its site, so it backs off once a tap
      // has made the site its target or put it on screen (BUG-033).
      'a home reset backs off from a site a tap opens (BUG-033)': (
        page: _threeBases,
        setup: [Tap(0), Login(0), Tap(1), Login(1)],
        script: [UnloadSite(0), Tap(0)],
      ),
      // The site on screen keeps its place, its webview built afresh: a
      // reset that unloaded it left LAZY-003's placeholder (LAZY-007).
      'a home reset of the site on screen keeps it loaded (LAZY-007)': (
        page: _threeBases,
        setup: [Tap(0), Login(0), Tap(1), Login(1)],
        script: [UnloadSite(1), Tap(0)],
      ),
      // A jar that does not answer: what the capture could not read stays
      // as stored, and a restore that cannot read, empty or refill the jar
      // leaves its target unshown, whatever lands meanwhile (ISO-014).
      'an unload whose capture the jar refuses keeps the stored session '
          '(ISO-014)': (
        page: _oneDomain,
        setup: [..._oneSignedIn, Fails(Fault.jarRead)],
        script: [Tap(1), Tap(0)],
      ),
      'a restore whose nuke the jar refuses leaves its target unshown '
          '(ISO-014)': (
        page: _mixed,
        setup: [..._oneSignedIn, Fails(Fault.jarClear)],
        script: [Tap(2)],
      ),
      'a refill the jar refuses writes the rest, then leaves its target '
          'unshown (ISO-014)': (
        page: _mixed,
        setup: [..._slot2Behind, Fails(Fault.jarWrite)],
        script: [Tap(2)],
      ),
      'a second tap reads the jar a restore emptied (BUG-032)': (
        page: _oneDomain,
        setup: _oneSignedIn,
        script: [Tap(0), Tap(0)],
      ),
      'an unload captures a site a switch already unloaded (BUG-032)': (
        page: _mixed,
        setup: _slot0Behind,
        script: [Pressure(), Pressure(), Tap(1)],
      ),
      'an unload removes the position it took before a move (BUG-029)': (
        page: _mixed,
        setup: _slot2Behind,
        script: [Pressure(), Pressure(), Move(0, to: 2)],
      ),
      'a superseded switch leaves the screen on a site it unloaded (BUG-029)': (
        page: _oneDomain,
        setup: _oneSignedIn,
        script: [Tap(1), Move(0, to: 2)],
      ),
      'a double tap unmarks its target before pressure (CONT-003)': (
        page: _mixedContainers,
        setup: _slot2Behind,
        script: [Tap(2), Tap(2), Pressure(), Pressure()],
      ),
      'a superseded switch disposes the site a tap back opens (BUG-033)': (
    page: _oneDomain,
    setup: _oneSignedIn,
    script: [Tap(1), Tap(0)],
  ),
  'an eviction under way disposes the site a tap opens (BUG-033)': (
        page: _mixed,
        setup: _slot2Behind,
        script: [Pressure(), Pressure(), Tap(2)],
      ),
    };

/// Tabs (TAB-003): pages whose first site starts with a second tab, from
/// that site on screen, loaded behind the third, or unloaded with its state
/// saved.
const _tabPages = <String, WalkPage>{
  'mixed, shared jar': _mixed,
  'mixed, containers': _mixedContainers,
};

const _tabSetups = <String, List<SiteAction>>{
  'one site signed in': _oneSignedIn,
  'slot 0 signed in behind': _slot0Behind,
  // Slot 0's state is saved when slot 1, on its base domain, unloads it.
  'slot 0 unloaded with its state': [Tap(0), Login(0), Tap(1)],
};

const _tabAlphabet = <SiteAction>[
  OpenTab(0, tab: 1),
  NewTab(0),
  CloseTab(0, tab: 0),
  DuplicateTab(0),
  Tap(0),
  Tap(1),
  GoHome(),
  Pressure(),
];

/// Webspaces (WEBSPACE-013): `All`, then one of the two sites on a base
/// domain and one of the site apart, chosen on the list, from the list with
/// one site signed in, or with a second loaded behind it.
const _spaces = [
  [0, 1],
  [2],
];

const _spaceSetups = <String, List<SiteAction>>{
  'home, one site signed in': [..._oneSignedIn, GoHome()],
  'home, slot 2 signed in behind': [..._slot2Behind, GoHome()],
};

const _spaceAlphabet = <SiteAction>[
  Tap(0),
  Tap(2),
  SwitchWebspace(0),
  SwitchWebspace(1),
  SwitchWebspace(2),
  GoHome(),
  Pressure(),
];

/// Scripts whose platform fails at something from their setup on, so each
/// step the model takes only where its world lets it fail is taken too:
/// the proxy rule a nested open or a wake's check moves (PROXY-008), and
/// the network a webspace switch asks after (WEBSPACE-013).
final _failing =
    <
      String,
      ({
        ActivationWorld Function() world,
        List<SiteAction> setup,
        List<SiteAction> script,
      })
    >{
      'a nested open whose proxy the platform refuses goes no further '
          '(PROXY-008)': (
        world: () => ActivationWorld(
          _launches['mixed, containers, from launch']!.page,
          launch: _launches['mixed, containers, from launch']!.launch,
          proxies: _proxied['mismatched proxies'],
          nestedOpens: true,
        ),
        setup: const [Fails(Fault.proxy)],
        script: const [OpenNested(2)],
      ),
      'a wake whose route the platform refuses opens no check there '
          '(PROXY-008)': (
        world: () => ActivationWorld(
          _launches['mixed, containers, from launch']!.page,
          launch: _launches['mixed, containers, from launch']!.launch,
          proxies: _proxied['mismatched proxies'],
          wakes: true,
        ),
        setup: const [Fails(Fault.proxy)],
        script: const [Background(), Wake()],
      ),
      'a webspace switch offline unloads nothing (WEBSPACE-013)': (
        world: () => ActivationWorld(_mixed, spaces: _spaces),
        setup: [
          ..._spaceSetups['home, slot 2 signed in behind']!,
          const Fails(Fault.network),
        ],
        script: const [SwitchWebspace(1)],
      ),
    };

/// A switch race, at two preemptions: a switch that leaves the
/// site an activation is opening, and one a tap lands on while it unloads.
const _spaceRegressions = <String, List<SiteAction>>{
  'a switch unloads the site a tap is opening (WEBSPACE-013)': [
    Tap(2),
    SwitchWebspace(1),
  ],
  'a tap opens a site a switch is unloading (WEBSPACE-013)': [
    SwitchWebspace(1),
    Tap(2),
  ],
};

/// An archive holding the site apart (ARCH-007, ARCH-014): moved in and
/// never opened, or open and loaded behind the site on screen.
const _archiveSetups = <String, List<SiteAction>>{
  'site 3 archived, never loaded': [ArchiveSite(2), Tap(0)],
  'site 3 archived, loaded behind': [Tap(2), ArchiveSite(2), Tap(0)],
};

const _archiveAlphabet = <SiteAction>[
  CloseArchive(),
  Tap(0),
  Tap(2),
  GoHome(),
  Pressure(),
];

const _archiveLength = 2;

/// A close race, at two preemptions: a frame landing while the
/// close waits on its storage, which built the site it had let go again on
/// the container it was about to delete.
const _archiveRegressions = <String, List<SiteAction>>{
  'a frame during a close builds the site it let go (ARCH-014)': [
    CloseArchive(),
    Tap(0),
  ],
  'a tap opens an archived site the close is taking off the list (ARCH-014)':
      [CloseArchive(), Tap(2)],
};

/// A delete of site 1 (BUG-038): the site on screen, or loaded behind it.
const _deleteSetups = <String, List<SiteAction>>{
  'site 1 on screen': [Tap(0)],
  'site 1 loaded behind': [Tap(0), Tap(2)],
};

const _deleteAlphabet = <SiteAction>[
  Delete(),
  Tap(0),
  Tap(2),
  GoHome(),
  Pressure(),
];

const _deleteLength = 2;

/// The race the delete's old order lost, at two preemptions: it
/// deleted the container before the commit took the site off the list, so
/// a tap landing meanwhile built the site again on it.
const _deleteRegressions = <String, List<SiteAction>>{
  'a tap on a site being deleted lands before its container goes (CONT-010)':
      [Delete(), Tap(0)],
};

/// Site 1 on its link tab (LIR-034), on screen or loaded behind, under one
/// process-wide proxy: the tab runs as site 1, on site 1's route, until a
/// reroute runs it as site 3, on another (LIR-024); or already as site 3,
/// with site 3 loaded behind.
const _rerouteSetups = <String, List<SiteAction>>{
  'site 1 on its link tab': [Tap(0), OpenTab(0, tab: 1)],
  'site 1 on its link tab, behind': [Tap(0), OpenTab(0, tab: 1), Tap(1)],
  'site 1 on its link tab as site 3, site 3 behind': [
    Tap(0),
    OpenTab(0, tab: 1),
    Reroute(),
    Tap(2),
    Tap(0),
  ],
};

const _rerouteAlphabet = <SiteAction>[
  Reroute(),
  OpenTab(0, tab: 0),
  OpenTab(0, tab: 1),
  Tap(0),
  Tap(1),
  Tap(2),
  GoHome(),
  Pressure(),
];

const _rerouteLength = 2;

/// A tab race the code once lost, at two preemptions.
const _tabRegressions =
    <String, ({List<SiteAction> setup, List<SiteAction> script})>{
      'an activation restores the state of a tab closed meanwhile': (
        setup: [Tap(0), Login(0), Tap(1)],
        script: [Tap(0), CloseTab(0, tab: 0)],
      ),
      'going home captures under the tab a switch moves to': (
        setup: _oneSignedIn,
        script: [OpenTab(0, tab: 1), GoHome()],
      ),
    };

const _alphabet = <SiteAction>[
  Tap(0),
  Tap(1),
  Tap(2),
  GoHome(),
  Pressure(),
  Move(0, to: 2),
  Move(2, to: 0),
];

/// Every script of exactly [length] actions over [alphabet].
List<List<SiteAction>> _scripts(
  int length, {
  List<SiteAction> alphabet = _alphabet,
}) => length == 0
    ? const [[]]
    : [
        for (final head in _scripts(length - 1, alphabet: alphabet))
          for (final action in alphabet) [...head, action],
      ];

int _env(String name, {required int fallback}) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

int get _length => _env('SCHEDULE_LENGTH', fallback: 3);

/// Whether the search prunes by the steps' footprints (`tableCommutes`).
bool get _reduced => Platform.environment['SCHEDULE_REDUCTION'] != 'off';

int get _preemptions =>
    _env('SCHEDULE_PREEMPTIONS', fallback: _reduced ? 2 : 1);

/// The bounds the named regressions were found at: a preemption, and two,
/// past the one the search ran at then.
const _onePast = 2;
const _twoPast = 3;

/// The schedules every search in this file ran to their end, and those it
/// stopped with every option left asleep.
var _ran = 0;
var _stopped = 0;

Future<void> _expectEvery({
  required ScheduledWorld<SiteAction> Function() world,
  required List<SiteAction> setup,
  required List<SiteAction> script,
  required int preemptions,
}) async {
  final search = await expectEveryScheduleHolds(
    world: world,
    setup: setup,
    script: script,
    preemptions: preemptions,
    commutes: _reduced ? tableCommutes : null,
  );
  _ran += search.runs;
  _stopped += search.stopped;
}

/// A launch's alphabet is larger, so its scripts are a step shorter.
int get _launchLength => _env('SCHEDULE_LAUNCH_LENGTH', fallback: 2);

/// A tab script's alphabet is larger too.
int get _tabLength => _env('SCHEDULE_TAB_LENGTH', fallback: 2);

/// A wake needs the app off screen first, so its scripts run one longer.
int get _wakeLength => _env('SCHEDULE_WAKE_LENGTH', fallback: 3);

int get _dnsLength => _env('SCHEDULE_DNS_LENGTH', fallback: 3);

int get _spaceLength => _env('SCHEDULE_SPACE_LENGTH', fallback: 2);

/// `SCHEDULE_SHARD=i/n` divides the largest sweeps by script, so one heavy
/// world cannot leave the other cores idle. Other tests run every nth from
/// the ith, keeping each regression and reduction comparison whole.
/// Unset, this process runs every script and test.
final _shard = switch (Platform.environment['SCHEDULE_SHARD']?.split('/')) {
  [final i, final n] => (at: int.parse(i), of: int.parse(n)),
  _ => (at: 0, of: 1),
};
var _declared = 0;

Iterable<List<SiteAction>> _shardedScripts(int length) =>
    shardItems(_scripts(length), index: _shard.at, count: _shard.of);

/// A schedule test, untimed: an exhaustive run takes as long as its bound.
void _scheduleTest(
  String name, {
  required Future<void> Function() body,
  bool splitScripts = false,
}) {
  final assigned = _declared++ % _shard.of == _shard.at;
  if (!splitScripts && !assigned) return;
  // Flutter captures a stack for every async callback. Keep native error
  // stacks during exhaustive searches; opt into extra chains for debugging.
  test(
    name,
    () => Chain.disable(
      body,
      when: Platform.environment['SCHEDULE_STACK_CHAINS'] != '1',
    ),
    timeout: Timeout.none,
  );
}

/// One world of each kind with its setup and inputs, and the length of
/// script whose every schedule within two preemptions runs in seconds:
/// where the reduced search is held to the full one.
final _samples =
    <
      String,
      ({
        ActivationWorld Function() world,
        List<SiteAction> setup,
        List<SiteAction> alphabet,
        int length,
      })
    >{
      'one base domain, shared jar, one site signed in': (
        world: () => ActivationWorld(_oneDomain),
        setup: _oneSignedIn,
        alphabet: _alphabet,
        length: 2,
      ),
      'mixed, containers, small caps': (
        world: () => ActivationWorld(
          _mixedContainers,
          caps: (loaded: 2, resident: 1),
        ),
        setup: _slot2Behind,
        alphabet: _alphabet,
        length: 2,
      ),
      'tabs, mixed, shared jar, slot 0 unloaded with its state': (
        world: () => ActivationWorld(_mixed, tabbed: true),
        setup: _tabSetups['slot 0 unloaded with its state']!,
        alphabet: _tabAlphabet,
        length: 2,
      ),
      'mixed, shared jar, from launch, mismatched proxies, nested opens': (
        world: () => ActivationWorld(
          _mixed,
          launch: _launches['mixed, shared jar, from launch']!.launch,
          proxies: _proxied['mismatched proxies'],
          nestedOpens: true,
        ),
        setup: const [],
        alphabet: _nestedAlphabet,
        length: 2,
      ),
      'mixed, containers, nested opens and background wakes': (
        world: () => ActivationWorld(
          _mixedContainers,
          proxies: _proxied['mismatched proxies'],
          nestedOpens: true,
          wakes: true,
        ),
        setup: const [Tap(0)],
        alphabet: _nestedWakeAlphabet,
        length: 3,
      ),
      'webspaces, shared jar, home, slot 2 signed in behind': (
        world: () => ActivationWorld(_mixed, spaces: _spaces),
        setup: _spaceSetups['home, slot 2 signed in behind']!,
        alphabet: _spaceAlphabet,
        length: 2,
      ),
      'delete, containers, site 1 loaded behind': (
        world: () => ActivationWorld(_mixedContainers, deletes: true),
        setup: _deleteSetups['site 1 loaded behind']!,
        alphabet: _deleteAlphabet,
        length: 2,
      ),
    };

void main() {
  setUpAll(
    () => TorService.overrideEngine(
      TorEngine(
        runtime: FakeTorRuntime(isAvailable: false),
        sessionSecret: 'walk',
      ),
    ),
  );
  tearDownAll(StepTraces.instance.writeIfAsked);
  tearDownAll(expectOnlyOwedMeets);
  tearDownAll(() {
    if ((Platform.environment['SCHEDULE_STATS'] ?? '').isEmpty) return;
    // ignore: avoid_print
    print(
      'Schedules: $_ran run to their end, $_stopped stopped asleep, at '
      '$_preemptions preemptions${_reduced ? ', reduced' : ''}',
    );
  });

  for (final MapEntry(key: pageName, value: page) in _pages.entries) {
    for (final MapEntry(key: setupName, value: setup) in _setups.entries) {
      _scheduleTest('$pageName, $setupName: every schedule holds',
          splitScripts: true,
          body: () async {
        for (var length = 1; length <= _length; length++) {
          for (final script in _shardedScripts(length)) {
            await _expectEvery(
              world: () => ActivationWorld(page),
              setup: setup,
              script: script,
              preemptions: _preemptions,
            );
          }
        }
      });
    }
  }

  for (final MapEntry(key: name, value: (:page, :launch))
      in _launches.entries) {
    _scheduleTest('$name: every schedule holds', body: () async {
      for (var length = 1; length <= _launchLength; length++) {
        for (final script in _scripts(length, alphabet: _launchAlphabet)) {
          await _expectEvery(
            world: () => ActivationWorld(page, launch: launch),
            setup: const [],
            script: script,
            preemptions: _preemptions,
          );
        }
      }
    });
  }

  for (final MapEntry(key: name, value: (:page, :launch))
      in _launches.entries) {
    for (final MapEntry(key: proxyName, value: proxies) in _proxied.entries) {
      _scheduleTest('$name, $proxyName: every schedule holds', body: () async {
        for (var length = 1; length <= _launchLength; length++) {
          for (final script in _scripts(length, alphabet: _launchAlphabet)) {
            await _expectEvery(
              world: () =>
                  ActivationWorld(page, launch: launch, proxies: proxies),
              setup: const [],
              script: script,
              preemptions: _preemptions,
            );
          }
        }
      });
    }
  }

  for (final MapEntry(key: name, value: (:page, :launch))
      in _launches.entries) {
    for (final proxyName in ['mismatched proxies', 'two Tor exits']) {
      _scheduleTest('$name, $proxyName, nested opens: every schedule holds',
          body: () async {
        for (var length = 1; length <= _launchLength; length++) {
          for (final script in _scripts(length, alphabet: _nestedAlphabet)) {
            await _expectEvery(
              world: () => ActivationWorld(
                page,
                launch: launch,
                proxies: _proxied[proxyName],
                nestedOpens: true,
              ),
              setup: const [],
              script: script,
              preemptions: _preemptions,
            );
          }
        }
      });
    }
  }

  for (final MapEntry(key: name, value: (:page, :launch))
      in _launches.entries) {
    for (final proxyName in ['mismatched proxies', 'two Tor exits']) {
      _scheduleTest('$name, $proxyName, background wakes: every schedule holds',
          body: () async {
        for (var length = 1; length <= _wakeLength; length++) {
          for (final script in _scripts(length, alphabet: _wakeAlphabet)) {
            await _expectEvery(
              world: () => ActivationWorld(
                page,
                launch: launch,
                proxies: _proxied[proxyName],
                wakes: true,
              ),
              setup: const [],
              script: script,
              preemptions: _preemptions,
            );
          }
        }
      });
    }
  }

  for (final MapEntry(key: setupName, value: setup) in {
    'one site on screen': const [Tap(0)],
    'two sites loaded': const [Tap(1), Tap(0)],
  }.entries) {
    _scheduleTest('mixed, containers, mismatched proxies, $setupName, nested opens '
        'and background wakes: every schedule holds', body: () async {
      for (var length = 1; length <= _wakeLength; length++) {
        for (final script in _scripts(length, alphabet: _nestedWakeAlphabet)) {
          await _expectEvery(
            world: () => ActivationWorld(
              _mixedContainers,
              proxies: _proxied['mismatched proxies'],
              nestedOpens: true,
              wakes: true,
            ),
            setup: setup,
            script: script,
            preemptions: _preemptions,
          );
        }
      }
    });
  }

  for (final MapEntry(key: pageName, value: page) in {
    'mixed, shared jar': _mixed,
    'mixed, containers': _mixedContainers,
  }.entries) {
    for (final MapEntry(key: setupName, value: setup) in {
      'one site signed in': _oneSignedIn,
      'slot 2 signed in behind': _slot2Behind,
    }.entries) {
      _scheduleTest(
          '$pageName, $setupName, DNS downloads: every schedule holds',
          body: () async {
        for (var length = 1; length <= _dnsLength; length++) {
          for (final script in _scripts(length, alphabet: _dnsAlphabet)) {
            await _expectEvery(
              world: () => ActivationWorld(page, dns: _dnsSites),
              setup: setup,
              script: script,
              preemptions: _preemptions,
            );
          }
        }
      });
    }
  }

  group('wake regressions', () {
    final (:page, :launch) = _launches['mixed, containers, from launch']!;
    for (final MapEntry(key: name, value: script) in _wakeRegressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(
            page,
            launch: launch,
            proxies: _proxied['mismatched proxies'],
            wakes: true,
          ),
          setup: const [],
          script: script,
          preemptions: _twoPast,
        );
      });
    }
  });

  group('nested regressions', () {
    final (:page, :launch) = _launches['mixed, containers, from launch']!;
    for (final MapEntry(key: name, value: script)
        in _nestedRegressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(
            page,
            launch: launch,
            proxies: _proxied['mismatched proxies'],
            nestedOpens: true,
          ),
          setup: const [],
          script: script,
          preemptions: _twoPast,
        );
      });
    }
  });

  // Caps three sites reach: two loaded, one of them resident.
  for (final MapEntry(key: name, value: page) in _pages.entries) {
    _scheduleTest('$name, small caps: every schedule holds', splitScripts: true,
        body: () async {
      for (var length = 1; length <= _length; length++) {
        for (final script in _shardedScripts(length)) {
          await _expectEvery(
            world: () =>
                ActivationWorld(page, caps: (loaded: 2, resident: 1)),
            setup: _slot2Behind,
            script: script,
            preemptions: _preemptions,
          );
        }
      }
    });
  }

  for (final MapEntry(key: pageName, value: page) in _tabPages.entries) {
    for (final MapEntry(key: setupName, value: setup) in _tabSetups.entries) {
      _scheduleTest('tabs, $pageName, $setupName: every schedule holds',
          body: () async {
        for (var length = 1; length <= _tabLength; length++) {
          for (final script in _scripts(length, alphabet: _tabAlphabet)) {
            await _expectEvery(
              world: () => ActivationWorld(page, tabbed: true),
              setup: setup,
              script: script,
              preemptions: _preemptions,
            );
          }
        }
      });
    }
  }

  for (final page in [_mixed, _mixedContainers]) {
    for (final MapEntry(key: setupName, value: setup) in _spaceSetups.entries) {
      _scheduleTest(
          'webspaces, ${page.containers ? 'containers' : 'shared jar'}, '
          '$setupName: every schedule holds', body: () async {
        for (var length = 1; length <= _spaceLength; length++) {
          for (final script in _scripts(length, alphabet: _spaceAlphabet)) {
            await _expectEvery(
              world: () => ActivationWorld(page, spaces: _spaces),
              setup: setup,
              script: script,
              preemptions: _preemptions,
            );
          }
        }
      });
    }
  }

  for (final MapEntry(key: setupName, value: setup)
      in _archiveSetups.entries) {
    _scheduleTest('archive, containers, $setupName: every schedule holds',
        body: () async {
      for (var length = 1; length <= _archiveLength; length++) {
        for (final script in _scripts(length, alphabet: _archiveAlphabet)) {
          await _expectEvery(
            world: () => ActivationWorld(_mixedContainers, archived: true),
            setup: setup,
            script: script,
            preemptions: _preemptions,
          );
        }
      }
    });
  }

  for (final MapEntry(key: setupName, value: setup)
      in _deleteSetups.entries) {
    _scheduleTest('delete, containers, $setupName: every schedule holds',
        body: () async {
      for (var length = 1; length <= _deleteLength; length++) {
        for (final script in _scripts(length, alphabet: _deleteAlphabet)) {
          await _expectEvery(
            world: () => ActivationWorld(_mixedContainers, deletes: true),
            setup: setup,
            script: script,
            preemptions: _preemptions,
          );
        }
      }
    });
  }

  for (final MapEntry(key: setupName, value: setup)
      in _rerouteSetups.entries) {
    _scheduleTest(
        'reroute (LIR-024), containers, $setupName: every schedule holds',
        body: () async {
      for (var length = 1; length <= _rerouteLength; length++) {
        for (final script in _scripts(length, alphabet: _rerouteAlphabet)) {
          await _expectEvery(
            world: () => ActivationWorld(
              _mixedContainers,
              proxies: _proxied['mismatched proxies'],
              rehosts: true,
            ),
            setup: setup,
            script: script,
            preemptions: _preemptions,
          );
        }
      }
    });
  }

  group('delete regressions', () {
    for (final MapEntry(key: name, value: script)
        in _deleteRegressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(_mixedContainers, deletes: true),
          setup: _deleteSetups['site 1 on screen']!,
          script: script,
          preemptions: _onePast,
        );
      });
    }
  });

  // The frame check holds what a step's code changes to what its table
  // declares; each mistake a table that declares less than its code does.
  group('planted frame mistakes', () {
    for (final m in FrameMistake.values) {
      final (:setup, :script, :undeclared) = switch (m) {
        FrameMistake.deleteDropKeepsWebView => (
          setup: _deleteSetups['site 1 on screen']!,
          script: const <SiteAction>[Delete()],
          undeclared: 'built, hist in deleteDropReply',
        ),
      };
      _scheduleTest('${m.name} is caught', body: () async {
        await expectLater(
          expectEveryScheduleHolds(
            world: () => ActivationWorld(
              _mixedContainers,
              deletes: true,
              declared: frameMistake(m),
            ),
            setup: setup,
            script: script,
            preemptions: 0,
            commutes: null,
          ),
          throwsA(
            isA<TestFailure>().having(
              (e) => e.message,
              'message',
              contains(undeclared),
            ),
          ),
        );
      });
    }
  });

  group('archive regressions', () {
    for (final MapEntry(key: name, value: script)
        in _archiveRegressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(_mixedContainers, archived: true),
          setup: _archiveSetups['site 3 archived, loaded behind']!,
          script: script,
          preemptions: _onePast,
        );
      });
    }
  });

  group('a platform that fails', () {
    for (final MapEntry(key: name, value: (:world, :setup, :script))
        in _failing.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: world,
          setup: setup,
          script: script,
          preemptions: _onePast,
        );
      });
    }
  });

  group('webspace regressions', () {
    for (final MapEntry(key: name, value: script)
        in _spaceRegressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(_mixed, spaces: _spaces),
          setup: _spaceSetups['home, slot 2 signed in behind']!,
          script: script,
          preemptions: _onePast,
        );
      });
    }
  });

  group('tab regressions', () {
    for (final MapEntry(key: name, value: (:setup, :script))
        in _tabRegressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(_mixed, tabbed: true),
          setup: setup,
          script: script,
          preemptions: _onePast,
        );
      });
    }
  });

  group('launch regressions', () {
    final (:page, :launch) = _launches['mixed, shared jar, from launch']!;
    for (final MapEntry(key: name, value: script)
        in _launchRegressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(page, launch: launch),
          setup: const [],
          script: script,
          preemptions: _onePast,
        );
      });
    }
  });

  group('regressions', () {
    for (final MapEntry(key: name, value: (:page, :setup, :script))
        in _regressions.entries) {
      _scheduleTest(name, body: () async {
        await _expectEvery(
          world: () => ActivationWorld(page),
          setup: setup,
          script: script,
          preemptions: _onePast,
        );
      });
    }
  });

  // The pruned search keeps every end state and every failure of the full
  // one: on scripts short enough to run every schedule within two
  // preemptions, both reach the same ones (schedules.dart says why).
  group('the reduced search', () {
    for (final MapEntry(key: name, value: (:world, :setup, :alphabet, :length))
        in _samples.entries) {
      _scheduleTest('$name: reaches every end and failure every schedule does',
          body: () async {
        var every = 0;
        var reduced = 0;
        for (var n = 1; n <= length; n++) {
          for (final script in _scripts(n, alphabet: alphabet)) {
            Future<ScheduleSearch> search(Commutes? commutes) =>
                exploreSchedules(
                  world: world,
                  setup: setup,
                  script: script,
                  preemptions: 2,
                  commutes: commutes,
                  toTheEnd: true,
                );
            final all = await search(null);
            final pruned = await search(tableCommutes);
            expect(pruned.ends, all.ends, reason: '$script');
            expect(
              pruned.failures.keys.toSet(),
              all.failures.keys.toSet(),
              reason: '$script',
            );
            every += all.runs;
            reduced += pruned.runs + pruned.stopped;
          }
        }
        expect(reduced, lessThanOrEqualTo(every));
      });
    }
  });
}
