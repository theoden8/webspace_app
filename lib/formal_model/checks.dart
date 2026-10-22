// The worlds formal/activation.tla is checked in and what each must show:
// a world's invariants hold, a witness is reached, a planted mistake is
// caught. Every check is one value of an enum here, so a mistake cannot be
// planted without naming the check that catches it; models.dart prints a
// TLC config per check and the list formal/check.sh runs.

import 'package:webspace/services/model_names.dart';

/// An operator of `activation_base` a world replaces with a definition of
/// `activation.tla` (`Route <- RouteSplit`).
enum Env {
  awaySpaces(op: ModelConst.away, by: 'AwaySpaces'),
  proxyGlobal(op: ModelConst.contending, by: 'ProxyGlobal'),
  globalProxy(op: ModelConst.globalProxy, by: 'GlobalOn'),
  routerContending(op: ModelConst.contending, by: 'RouterShared'),
  routerShared(op: ModelConst.routed, by: 'RouterShared'),
  routeSplit(op: ModelConst.route, by: 'RouteSplit'),
  linkAny(op: ModelConst.linked, by: 'LinkAny'),
  linkTab(op: ModelConst.links, by: 'LinkOne'),
  torOn(op: ModelConst.torRuntime, by: 'TorOn'),
  exitSplit(op: ModelConst.torExit, by: 'ExitSplit'),
  notifyAll(op: ModelConst.notified, by: 'NotifyAll'),
  wakesUp(op: ModelConst.waking, by: 'WakesUp'),
  dnsAsk(op: ModelConst.siteLevel, by: 'DnsAsk'),
  dnsTwo(op: ModelConst.dnsLevels, by: 'DnsTwo'),
  residentOne(op: ModelConst.maxResident, by: 'ResidentOne'),
  capTwo(op: ModelConst.maxLoaded, by: 'CapTwo'),
  archiveOne(op: ModelConst.archive, by: 'ArchiveOne'),
  deleteOne(op: ModelConst.deletable, by: 'DeleteOne'),
  resetOne(op: ModelConst.resettable, by: 'ResetOne'),
  incognitoOne(op: ModelConst.incognito, by: 'IncognitoOne'),
  /// A refused read keeps the set the site last saved, so what the jar
  /// held of its session since is lost (ISO-014).
  jarRefuses(
    op: ModelConst.jarRefuses,
    by: 'JarCanRefuse',
    givesUp: {Inv.noSessionLoss},
  ),
  proxyRefuses(op: ModelConst.proxyRefused, by: 'ProxyCanRefuse'),
  offline(op: ModelConst.online, by: 'Offline');

  const Env({required this.op, required this.by, this.givesUp = const {}});

  final ModelConst op;
  final String by;

  /// The invariants no world that sets it holds, by design.
  final Set<Inv> givesUp;
}

/// The invariants a world holds: every one but those its constants give up
/// ([Env.givesUp]).
List<Inv> invariantsOf(WorldSpec w) => [
  for (final i in Inv.values)
    if (!w.env.any((e) => e.givesUp.contains(i))) i,
];

/// How a world keeps the sites' cookies apart, as the app's `Isolation`
/// does: one shared jar the activation swaps, or a container per site.
enum Cookies { sharedJar, containers }

/// An invariant `activation.tla` states.
enum Inv {
  typeOK(reads: null),
  shownLoaded(atRest: true, reads: {ModelVar.current, ModelVar.loaded}),
  oneSitePerBase(reads: {ModelVar.loaded}),
  noSessionLoss(
    atRest: true,
    reads: {ModelVar.gone, ModelVar.jar, ModelVar.loaded, ModelVar.signedIn, ModelVar.stored},
  ),
  noForeignSession(atRest: true, reads: {ModelVar.jar, ModelVar.loaded, ModelVar.stored}),
  noShownEvicted(reads: {ModelVar.evictedShown}),
  leftHidden(reads: {ModelVar.current, ModelVar.fl, ModelVar.version}),
  loadedNotSaved(atRest: true, reads: {ModelVar.loaded, ModelVar.tier}),
  places(reads: {ModelVar.fl, ModelVar.holder}),
  oneRoute(
    reads: {
      ModelVar.active,
      ModelVar.headless,
      ModelVar.host,
      ModelVar.loaded,
      ModelVar.nested,
    },
  ),
  checksOffScreen(
    reads: {ModelVar.fore, ModelVar.headless},
    inductive: true,
  ),
  told(reads: {ModelVar.dns, ModelVar.told}),
  tabShown(reads: {ModelVar.built, ModelVar.hist}),
  tabFiles(reads: {ModelVar.file}),
  tabBound(reads: {ModelVar.active, ModelVar.built}),
  tabActive(atRest: true, reads: {ModelVar.active, ModelVar.built, ModelVar.loaded, ModelVar.tabs}),
  retired(
    atRest: true,
    reads: {ModelVar.boxes, ModelVar.current, ModelVar.gone, ModelVar.loaded, ModelVar.views},
  );

  const Inv({required this.reads, this.atRest = false, this.inductive = false});

  /// The model's variables its definition reads, through the operators it
  /// calls, null for every one: `footprint.py` holds it to the text. An
  /// action that writes none of them keeps the invariant as it found it.
  final Set<ModelVar>? reads;

  /// Whether it holds only at rest (`Idle =>`): then it also reads every
  /// row's place, which every step that ends a flow's wait writes.
  final bool atRest;

  /// Whether every step keeps it as it stands, each case closed by the
  /// step's definition, so it is proved for every number of inputs
  /// (`activation_invariants_proof`) and not only checked by TLC.
  final bool inductive;

  String get tla => this == typeOK ? 'TypeOK' : 'Inv_${_upper(name)}';
}

const _core = [
  Inv.typeOK,
  Inv.shownLoaded,
  Inv.noShownEvicted,
  Inv.loadedNotSaved,
  Inv.places,
];
const _jar = [Inv.oneSitePerBase, Inv.noSessionLoss, Inv.noForeignSession];
const _tabs = [Inv.tabShown, Inv.tabFiles, Inv.tabBound, Inv.tabActive];

/// A world `activation.tla` is checked in: its constants, and what holds
/// there ([holds] null for a world only a hand-written mistake runs in).
enum ActivationWorld {
  base(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 4,
    invariants: [..._core, ..._jar],
    holds:
        'shared jar: shown site loaded, one site per base, no session lost '
        'or crossed, no live target evicted, no loaded site saved',
  ),
  containers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 4,
    invariants: _core,
    holds:
        'containers: shown site loaded, no live target evicted, no loaded '
        'site saved',
  ),
  plain(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    invariants: [],
    holds: null,
  ),
  tabs(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    tabbed: {1},
    maxTabs: 3,
    invariants: [..._core, ..._jar, ..._tabs],
    holds:
        "site 1's tabs on the shared jar: the webview shows its tab's "
        'history, each file its own (TAB-003)',
  ),
  tabsContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    tabbed: {1},
    maxTabs: 3,
    invariants: [..._core, ..._jar, ..._tabs],
    holds: "site 1's tabs under containers: TAB-003 holds",
  ),
  tabsCold(
    cookies: Cookies.sharedJar,
    coldStart: true,
    inputs: 3,
    tabbed: {1},
    maxTabs: 3,
    invariants: [..._core, ..._jar, ..._tabs],
    holds:
        "site 1's tabs on the shared jar from launch: a preloaded webview "
        'shows its active tab (TAB-003)',
  ),
  coldstart(
    cookies: Cookies.sharedJar,
    coldStart: true,
    inputs: 3,
    invariants: [..._core, ..._jar],
    holds:
        "shared jar from launch: the last session's jar reaches no site, "
        'preloads included',
  ),
  coldstartContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 3,
    invariants: _core,
    holds: 'containers from launch: preloads keep every invariant',
  ),
  proxy(
    cookies: Cookies.sharedJar,
    coldStart: true,
    inputs: 3,
    env: {Env.proxyGlobal, Env.globalProxy, Env.routeSplit},
    invariants: [..._core, ..._jar, Inv.oneRoute],
    holds:
        'shared jar, two routes under one process-global proxy: one route '
        'loaded (PROXY-008)',
  ),
  proxyContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 3,
    env: {Env.proxyGlobal, Env.globalProxy, Env.routeSplit},
    invariants: [..._core, Inv.oneRoute],
    holds:
        'containers, two routes under one process-global proxy: one route '
        'loaded (PROXY-008)',
  ),
  capContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    env: {Env.residentOne, Env.capTwo},
    invariants: _core,
    holds:
        'containers under small caps: the cap and the cache clear keep every '
        'invariant',
  ),
  torContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 3,
    env: {Env.torOn, Env.exitSplit},
    invariants: [..._core, Inv.oneRoute],
    holds:
        'containers, two Tor sites on different exits: one exit loaded '
        '(TOR-025)',
  ),
  nestedContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 3,
    env: {Env.proxyGlobal, Env.globalProxy, Env.routeSplit, Env.linkAny},
    invariants: [..._core, Inv.oneRoute],
    holds:
        'containers, two routes, links opened nested: the screen and the '
        'loaded sites run one route (LIR-011)',
  ),
  nested(
    cookies: Cookies.sharedJar,
    coldStart: true,
    inputs: 3,
    env: {Env.proxyGlobal, Env.globalProxy, Env.routeSplit, Env.linkAny},
    invariants: [..._core, ..._jar, Inv.oneRoute],
    holds:
        'shared jar, two routes, links opened nested: the screen and the '
        'loaded sites run one route (LIR-011)',
  ),
  nestedTorContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 3,
    env: {Env.torOn, Env.exitSplit, Env.linkAny},
    invariants: [..._core, Inv.oneRoute],
    holds:
        'containers, two Tor exits, links opened nested: the screen and the '
        'loaded sites run one exit (TOR-014)',
  ),
  nestedRefusedContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 3,
    env: {Env.proxyGlobal, Env.globalProxy, Env.routeSplit, Env.linkAny, Env.proxyRefuses},
    invariants: [..._core, Inv.oneRoute],
    holds:
        'containers, two routes, a proxy rule the platform refuses: a nested '
        'open that could not move it puts up no screen (PROXY-008)',
  ),
  spacesOffline(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.awaySpaces, Env.offline},
    invariants: [..._core, ..._jar, Inv.leftHidden],
    holds:
        'shared jar, webspaces chosen offline: a switch unloads nothing '
        '(WEBSPACE-013)',
  ),
  spaces(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.awaySpaces},
    invariants: [..._core, ..._jar, Inv.leftHidden],
    holds:
        'shared jar, webspaces chosen on the list: no switch disposes the '
        'site on screen or one a tap opens (WEBSPACE-013)',
  ),
  spacesCold(
    cookies: Cookies.sharedJar,
    coldStart: true,
    inputs: 3,
    env: {Env.awaySpaces},
    invariants: [..._core, ..._jar, Inv.leftHidden],
    holds:
        'shared jar from launch, preloads beside webspace switches '
        '(WEBSPACE-013)',
  ),
  spacesContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    env: {Env.awaySpaces},
    invariants: [..._core, ..._jar, Inv.leftHidden],
    holds:
        'containers, webspaces chosen on the list: a switch unloads nothing '
        '(WEBSPACE-013, CONT-003)',
  ),
  wakeContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 4,
    env: {Env.proxyGlobal, Env.globalProxy, Env.routeSplit, Env.notifyAll, Env.wakesUp},
    invariants: [..._core, Inv.oneRoute, Inv.checksOffScreen],
    holds:
        'containers, two routes, a background wake: the checks and the '
        'loaded sites run one route (NOTIF-016)',
  ),
  nestedWakeContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    env: {
      Env.proxyGlobal,
      Env.globalProxy,
      Env.routeSplit,
      Env.linkAny,
      Env.notifyAll,
      Env.wakesUp,
    },
    allowed: {'Background', 'Foreground', 'NestedOpen', 'Wake'},
    invariants: [..._core, Inv.oneRoute, Inv.checksOffScreen],
    holds:
        'containers, two routes, a nested open beside a wake: no check runs '
        'beside the site its pop brings back on another route (BUG-037)',
  ),
  wakeTorContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 4,
    env: {Env.torOn, Env.exitSplit, Env.notifyAll, Env.wakesUp},
    invariants: [..._core, Inv.oneRoute, Inv.checksOffScreen],
    holds:
        'containers, two Tor exits, a background wake: the checks and the '
        'loaded sites run one exit (TOR-014)',
  ),
  dnsContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    env: {Env.dnsAsk, Env.dnsTwo},
    invariants: [..._core, Inv.told],
    holds:
        "containers, two DNS levels a download picks: every live view runs "
        "its site's level (DNS-022)",
  ),
  dns(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.dnsAsk, Env.dnsTwo},
    invariants: [..._core, Inv.told, ..._jar],
    holds:
        "shared jar, two DNS levels: every live view runs its site's level "
        "beside the jar's turns (DNS-022)",
  ),
  routerContainers(
    cookies: Cookies.containers,
    coldStart: true,
    inputs: 3,
    env: {Env.routerContending, Env.routeSplit, Env.routerShared},
    invariants: [..._core, Inv.oneRoute],
    holds:
        "containers under the router: the default session's sites run one "
        'route, repointed first (LIR-024)',
  ),
  tabsSpaces(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    tabbed: {1},
    maxTabs: 3,
    env: {Env.awaySpaces},
    allowed: {
      'CloseTab',
      'DuplicateTab',
      'GoHome',
      'NewTab',
      'OpenTab',
      'SpaceSwitch',
    },
    invariants: [..._core, ..._jar, ..._tabs, Inv.leftHidden],
    holds:
        "site 1's tabs on the shared jar beside webspace switches, the list "
        'reached by going home (TAB-003, WEBSPACE-013)',
  ),
  tabsRouterContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    tabbed: {1},
    maxTabs: 3,
    env: {Env.routerContending, Env.routeSplit, Env.routerShared},
    allowed: {'CloseTab', 'DuplicateTab', 'NewTab', 'OpenTab', 'Tap'},
    invariants: [..._core, ..._tabs, Inv.oneRoute],
    holds:
        "site 1's tabs under the router's shared session: the switches "
        'keep one route (LIR-024)',
  ),
  tabsRerouteContainers(
    cookies: Cookies.containers,
    coldStart: false,
    // A tab switch onto a rerouted tab reopens the slot as the fourth input:
    // a tap, the reroute, the switch and the tap it spawns.
    inputs: 4,
    tabbed: {1},
    maxTabs: 3,
    env: {
      Env.proxyGlobal,
      Env.globalProxy,
      Env.routeSplit,
      Env.linkTab,
    },
    allowed: {'GoHome', 'OpenTab', 'Pressure', 'Reroute', 'Tap'},
    invariants: [..._core, ..._tabs, Inv.oneRoute],
    holds:
        "site 1's link tab into site 3's domain under one process-wide "
        'proxy: a reroute or a tab switch that moves the slot to another '
        'site takes it out of the loaded sites and opens it again in the '
        'same turn (LIR-024, LIR-034)',
  ),
  tabsResetContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    // The reset's site, loaded off screen at the start (ResetOne).
    tabbed: {3},
    maxTabs: 3,
    env: {Env.resetOne},
    allowed: {'HomeLanding', 'NewTab', 'OpenTab', 'Pressure', 'Tap', 'UnloadSite'},
    invariants: [..._core, ..._tabs],
    holds:
        "site 3's tabs beside a reset's landings at home: a loaded site "
        'switches to the tab its landing names, one with no webview takes '
        'it as its pointer (TAB-014)',
  ),
  archiveContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    env: {Env.archiveOne},
    invariants: [..._core, Inv.retired],
    holds:
        'containers, an archive closed beside taps, pressure and frames: '
        'none of its sites stays loaded, mounted or on disk (ARCH-007, '
        'ARCH-014)',
  ),
  incognito(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.incognitoOne},
    invariants: [..._core, ..._jar],
    holds:
        'shared jar, an incognito site loaded: a switch empties the jar and '
        'sets its session back from memory (INC-001)',
  ),
  jarRefuses(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.jarRefuses},
    invariants: [..._core, Inv.oneSitePerBase, Inv.noForeignSession],
    holds:
        'shared jar that may refuse a read, the nuke or a write: no site is '
        'shown on another\'s session (ISO-014)',
  ),
  archive(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.archiveOne},
    invariants: [..._core, ..._jar, Inv.retired],
    holds:
        "shared jar, an archive closed beside taps and the jar's turns: its "
        'sites leave the list and the jar keeps every other session (ARCH-007)',
  ),
  archiveJarRefuses(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.archiveOne, Env.jarRefuses},
    allowed: {'CloseArchive', 'Pressure', 'Tap'},
    invariants: [..._core, Inv.noForeignSession],
    holds:
        "shared jar that may refuse, an archive's close beside an unload "
        "whose capture the jar refused: no site is shown on another's "
        'session (ISO-014, ARCH-014)',
  ),
  delete(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.deleteOne},
    invariants: [..._core, ..._jar, Inv.retired],
    holds:
        "shared jar, the site on screen deleted beside taps and the jar's "
        'turns: every other session stays (CONT-010)',
  ),
  reset(
    cookies: Cookies.sharedJar,
    coldStart: false,
    inputs: 3,
    env: {Env.resetOne},
    invariants: [..._core, ..._jar],
    holds:
        'shared jar, a site off screen unloaded at a home reset beside taps '
        "and the jar's turns: every session stays (ISO-002)",
  ),
  deleteContainers(
    cookies: Cookies.containers,
    coldStart: false,
    inputs: 3,
    env: {Env.deleteOne},
    invariants: [..._core, Inv.retired],
    holds:
        'containers, the site on screen deleted beside taps and frames: it '
        'stays off the list, unloaded, unmounted and off the disk '
        '(CONT-010)',
  );

  const ActivationWorld({
    required this.cookies,
    required this.coldStart,
    required this.inputs,
    this.tabbed = const {},
    this.maxTabs = 1,
    this.env = const {},
    this.allowed,
    required this.invariants,
    required this.holds,
  });

  final Cookies cookies;
  final bool coldStart;
  final int inputs;
  final Set<int> tabbed;
  final int maxTabs;
  final Set<Env> env;

  /// The inputs that may land, null for every one.
  final Set<String>? allowed;
  final List<Inv> invariants;
  final String? holds;

  String get cfg => this == base ? 'activation' : 'activation_${_snake(name)}';

  WorldSpec get spec => (
    cookies: cookies,
    coldStart: coldStart,
    inputs: inputs,
    tabbed: tabbed,
    maxTabs: maxTabs,
    env: env,
    allowed: allowed,
  );
}

/// What a world of `activation.tla` is: its constants, how many inputs a
/// behavior takes, and which inputs may land ([allowed], null for every
/// one).
typedef WorldSpec = ({
  Cookies cookies,
  bool coldStart,
  int inputs,
  Set<int> tabbed,
  int maxTabs,
  Set<Env> env,
  Set<String>? allowed,
});

/// The model's constants [w] sets: those it replaces, its isolation and
/// launch, the tabs it follows, and those the base defines over them.
Set<ModelConst> constantsOf(WorldSpec w) {
  final own = {
    for (final e in w.env) e.op,
    if (w.cookies == Cookies.containers) ModelConst.containers,
    if (w.coldStart) ModelConst.coldStart,
    if (w.tabbed.isNotEmpty) ModelConst.tabbed,
    if (w.maxTabs > 1) ModelConst.maxTabs,
  };
  return {
    ...own,
    for (final c in ModelConst.values)
      if (c.follows.any(own.contains)) c,
  };
}

/// A behavior a world must reach: `Reach_<Name>` is violated, so the
/// interleavings its invariants constrain are not vacuous.
enum Witness {
  bailAfterUnload(
    world: ActivationWorld.base,
    doc: 'a switch superseded after its residency unloaded a site is reachable',
  ),
  turnQueued(
    world: ActivationWorld.base,
    doc: "a jar operation waiting for another's turn is reachable",
  ),
  backOff(
    world: ActivationWorld.base,
    doc:
        'an eviction backing off from a site that started activating is '
        'reachable',
  ),
  evictMidActivation(
    world: ActivationWorld.containers,
    doc: 'memory pressure disposing a site while an activation runs is reachable',
  ),
  movedMidFlight(
    world: ActivationWorld.base,
    doc: 'rows moving while a flow is in flight is reachable',
  ),
  routeSwitch(
    world: ActivationWorld.proxyContainers,
    doc: 'a tap unloading a proxy contender is reachable',
  ),
  capPicked(
    world: ActivationWorld.capContainers,
    doc: "a tap's plan picking by the loaded-site cap is reachable",
  ),
  exitSwitch(
    world: ActivationWorld.torContainers,
    doc: 'a tap unloading a Tor site on another exit is reachable',
  ),
  nestedBeside(
    world: ActivationWorld.nestedContainers,
    doc: 'a nested screen up beside a loaded site is reachable',
  ),
  nestedUnloads(
    world: ActivationWorld.nestedContainers,
    doc: 'a nested open unloading a site its screen would repoint is reachable',
  ),
  spaceUnloads(
    world: ActivationWorld.spaces,
    doc: 'a webspace switch unloading a site it stops showing is reachable',
  ),
  dnsTells(
    world: ActivationWorld.dnsContainers,
    doc: "a download's fold telling a live view a level is reachable",
  ),
  wakeBeside(
    world: ActivationWorld.wakeContainers,
    doc: 'a wake checking a site headless beside a loaded one is reachable',
  ),
  wakeSkips(
    world: ActivationWorld.wakeContainers,
    doc:
        'a wake passing over a site that may not run beside what runs is '
        'reachable',
  ),
  preloaded(
    world: ActivationWorld.coldstart,
    doc: 'a preload committing off screen is reachable',
  ),
  closeSupersedes(
    world: ActivationWorld.archiveContainers,
    doc: 'a close taking its sites off the list beside a tap in flight is '
        'reachable',
  ),
  incognitoKept(
    world: ActivationWorld.incognito,
    doc:
        'a restore setting a loaded incognito site\'s session back is '
        'reachable',
  ),
  deleteSupersedes(
    world: ActivationWorld.deleteContainers,
    doc: 'a delete taking the site on screen off the list beside a tap in '
        'flight is reachable',
  ),
  unrestored(
    world: ActivationWorld.jarRefuses,
    doc: 'a tap whose restore the jar refused landing on the webspace list '
        'is reachable',
  ),
  captureRefused(
    world: ActivationWorld.jarRefuses,
    doc: 'an unload whose capture the jar refused keeping the stored session '
        'is reachable',
  ),
  nestedRefused(
    world: ActivationWorld.nestedRefusedContainers,
    doc: 'a nested open whose proxy the platform refused ending before its '
        'screen is reachable',
  ),
  offline(
    world: ActivationWorld.spacesOffline,
    doc: 'a webspace switch that found the device offline is reachable',
  ),
  reopened(
    world: ActivationWorld.tabsRerouteContainers,
    doc:
        'a rebind that reroutes the slot on screen starting its activation '
        'in the same turn is reachable',
  ),
  rerouted(
    world: ActivationWorld.tabsRerouteContainers,
    doc:
        'a reroute that moves the slot on screen starting its activation in '
        'the same turn is reachable',
  ),
  landed(
    world: ActivationWorld.tabsResetContainers,
    doc: "a reset's landing that switches a loaded site to the tab it names "
        'is reachable',
  );

  const Witness({required this.world, required this.doc});

  final ActivationWorld world;
  final String doc;

  String get tla => 'Reach_${_upper(name)}';
}

/// The inputs a planted mistake's counterexample takes, out of those its
/// world lets land: a behavior of the slice is one of the world's, so a
/// violation found there is one the world has, and the search pays only for
/// the inputs it needs.
typedef Slice = ({Set<String> allowed});

/// A mistake an engine once had, planted in a copy of its tables or
/// definitions (`mutated` in models.dart), and where it is caught: [by]
/// is violated in [world], within its [slice] when one is named, and in
/// each world of [also].
enum Mutant {
  incognitonuked(
    world: ActivationWorld.incognito,
    by: Inv.noSessionLoss,
    doc:
        'a restore that sets back only the sites it saves signs a loaded '
        'incognito site out (INC-001, caught)',
  ),
  recapture(
    world: ActivationWorld.reset,
    slice: (allowed: {'Tap', 'UnloadSite'}),
    by: Inv.noSessionLoss,
    doc:
        'an unload that captures a site no longer loaded loses its session '
        '(BUG-032, caught)',
  ),
  nohome(
    world: ActivationWorld.delete,
    slice: (allowed: {'Tap', 'DeleteSite'}),
    by: Inv.shownLoaded,
    doc: 'a switch a delete of another site supersedes, staying on the site '
        'it unloaded (LAZY-007, caught)',
  ),
  markerbytarget(
    world: ActivationWorld.containers,
    slice: (allowed: {'Tap', 'Pressure'}),
    by: Inv.noShownEvicted,
    doc: 'a marker any activation of its target clears (CONT-003, caught)',
  ),
  noretry(
    world: ActivationWorld.base,
    slice: (allowed: {'Tap', 'Pressure'}),
    by: Inv.noShownEvicted,
    doc:
        'an eviction that does not ask again before it disposes (BUG-033, '
        'caught)',
  ),
  staleplan(
    world: ActivationWorld.base,
    slice: (allowed: {'Tap'}),
    by: Inv.noShownEvicted,
    doc:
        "a superseded switch's unload that disposes the site a newer tap "
        'opens (BUG-033, caught)',
  ),
  tierearly(
    world: ActivationWorld.base,
    slice: (allowed: {'Tap', 'GoHome'}),
    by: Inv.loadedNotSaved,
    doc:
        "a spared site left at savedForRestore, out of pressure's reach "
        '(BUG-033, caught)',
  ),
  pointerearly(
    world: ActivationWorld.tabs,
    by: Inv.tabBound,
    doc:
        'a switch moving the pointer before its nav read (BUG-036 attempt 1, '
        'caught)',
  ),
  takeany(
    world: ActivationWorld.tabs,
    slice: (allowed: {'Tap', 'CloseTab'}),
    by: Inv.tabShown,
    doc: 'a build taking bytes queued for another tab (caught)',
  ),
  captureatreply(
    world: ActivationWorld.tabs,
    by: Inv.tabFiles,
    doc:
        'a capture keyed at its reply, after a rebind (BUG-036 attempt 1, '
        'caught)',
  ),
  nukeignored(
    world: ActivationWorld.jarRefuses,
    by: Inv.noForeignSession,
    doc:
        'a restore that refills a jar whose nuke was refused shows its target '
        'on the session of a site it unloaded (ISO-014, caught)',
  ),
  preloadmismatch(
    world: ActivationWorld.proxy,
    slice: (allowed: {'Preload'}),
    by: Inv.oneRoute,
    doc: 'a preload loading a site on another route than a loaded one (caught)',
    also: {
      ActivationWorld.torContainers:
          'a preload loading a Tor site on another exit than a loaded one '
          '(caught)',
    },
  ),
  nestedonce(
    world: ActivationWorld.nestedContainers,
    by: Inv.oneRoute,
    doc: 'a nested open that does not ask again once the proxy moved (caught)',
  ),
  preloadunchecked(
    world: ActivationWorld.nestedContainers,
    by: Inv.oneRoute,
    doc:
        'a preload that commits beside a nested screen without asking again '
        '(caught)',
  ),
  spaceold(
    world: ActivationWorld.spaces,
    by: Inv.leftHidden,
    doc:
        'a switch that supersedes nothing: a tap in flight opens a site it '
        'left (caught)',
  ),
  wakeunchecked(
    world: ActivationWorld.wakeContainers,
    by: Inv.oneRoute,
    doc: "a wake's check that does not ask the rule (BUG-037 attempt 8, caught)",
  ),
  wakebesidenested(
    world: ActivationWorld.nestedWakeContainers,
    by: Inv.oneRoute,
    doc:
        "a wake's check beside a nested open in flight, whose pop brings the "
        'site on screen back on another route (BUG-037, caught)',
  ),
  wakebesidetap(
    world: ActivationWorld.wakeContainers,
    slice: (allowed: {'Tap', 'Background', 'Wake'}),
    by: Inv.oneRoute,
    doc:
        "a wake's check beside a tap in flight, whose plan ran before it "
        '(caught)',
  ),
  foldbeforelevel(
    world: ActivationWorld.dnsContainers,
    by: Inv.told,
    doc:
        'a fold that tells the views before the new app-wide level is in '
        'force (caught)',
  ),
  preloadunbound(
    world: ActivationWorld.tabsCold,
    slice: (allowed: {'Preload'}),
    by: Inv.tabActive,
    doc:
        "a preload's frame that sees its site unloaded binds no tab, so the "
        'webview it builds shows none (caught)',
  ),
  preloadbare(
    world: ActivationWorld.coldstart,
    by: Inv.noForeignSession,
    doc:
        "a preload loaded over the last session's jar runs on another site's "
        'session (NOTIF-017, caught)',
  ),
  closenoframe(
    world: ActivationWorld.archiveContainers,
    by: Inv.retired,
    doc:
        'a close deleting containers before the frame unmounts their '
        'webviews leaves one on disk (ARCH-014, caught)',
  ),
  deletenoframe(
    world: ActivationWorld.deleteContainers,
    by: Inv.retired,
    doc:
        'a delete deleting its container before the frame unmounts its '
        'webview leaves it on disk (CONT-010, caught)',
  ),
  noreopen(
    world: ActivationWorld.tabsRerouteContainers,
    by: Inv.shownLoaded,
    doc:
        'a rebind that reroutes the slot on screen and starts no activation '
        'leaves it unloaded (LIR-024, caught)',
  ),
  rerouteinplace(
    world: ActivationWorld.tabsRerouteContainers,
    by: Inv.oneRoute,
    doc:
        'a reroute that moves a loaded slot to another site under one '
        'process-wide proxy and keeps it loaded runs two routes (LIR-024, '
        'caught)',
  ),
  landinplace(
    world: ActivationWorld.tabsResetContainers,
    by: Inv.tabBound,
    doc:
        "a landing that moves a loaded site's pointer without switching its "
        'webview leaves it built for another tab (TAB-014, caught)',
  );

  const Mutant({
    required this.world,
    required this.by,
    required this.doc,
    this.slice,
    this.also = const {},
  });

  final ActivationWorld world;
  final Inv by;
  final String doc;
  final Slice? slice;
  final Map<ActivationWorld, String> also;

  /// Where the mistake is looked for in [world]: the world itself, or the
  /// part of it its [slice] lets land.
  WorldSpec get spec => _sliced(world, slice: slice, by: name);
}

/// [world], or the part of it [slice] lets land, for the mistake [by].
WorldSpec _sliced(
  ActivationWorld world, {
  required Slice? slice,
  required String by,
}) {
  final w = world.spec;
  if (slice == null) return w;
  assert(
    w.allowed == null || w.allowed!.containsAll(slice.allowed),
    '$by: a slice lets land only what its world does',
  );
  return (
    cookies: w.cookies,
    coldStart: w.coldStart,
    inputs: w.inputs,
    tabbed: w.tabbed,
    maxTabs: w.maxTabs,
    env: w.env,
    allowed: slice.allowed,
  );
}

/// How TLC shows a planted mistake.
sealed class Caught {
  const Caught();
}

/// An invariant is violated.
final class Breaks extends Caught {
  const Breaks(this.inv);

  final Inv inv;
}

/// A behavior ends outside `Done`: every config checks for one.
final class Deadlocks extends Caught {
  const Deadlocks();
}

/// A mistake of `activation.tla`'s hand-written environment, planted by
/// its `Mistake` constant.
enum HandMistake {
  noturns(
    world: ActivationWorld.base,
    slice: (allowed: {'Tap', 'GoHome'}),
    caught: Breaks(Inv.noSessionLoss),
    doc:
        'jar operations that do not wait for each other lose a session '
        '(BUG-032, caught)',
  ),
  keepturn(
    world: ActivationWorld.plain,
    caught: Deadlocks(),
    doc:
        'a jar operation that keeps its turn leaves the flows behind it '
        'waiting forever (deadlock, caught)',
  ),
  lateclear(
    world: ActivationWorld.coldstart,
    slice: (allowed: {'Preload'}),
    caught: Breaks(Inv.noSessionLoss),
    doc:
        "a launch clear outside the jar's turns empties a restored session "
        '(ISO-012, caught)',
  );

  const HandMistake({
    required this.world,
    this.slice,
    required this.caught,
    required this.doc,
  });

  final ActivationWorld world;
  final Slice? slice;
  final Caught caught;
  final String doc;

  /// Where the mistake is looked for ([Mutant.spec]).
  WorldSpec get spec => _sliced(world, slice: slice, by: name);
}

/// One run of TLC over `activation.tla`: the config it reads, the line its
/// output must carry, and the printed mutant it runs on, if any.
typedef Check = ({
  String cfg,
  WorldSpec world,
  String text,
  String expect,
  String label,
  Mutant? mutant,
});

/// Every check of `activation.tla`, from the enums above: a world's
/// invariants, each witness, each mutant in each world it is caught in,
/// each hand-written mistake; and each world [printed] for pairs no world
/// here can take, holding every invariant.
List<Check> activationChecks({
  required List<({String cfg, WorldSpec spec, String label})> printed,
}) {
  for (final w in ActivationWorld.values) {
    assert(
      w.invariants.every(invariantsOf(w.spec).contains),
      '${w.name} checks an invariant its constants give up',
    );
  }
  final checks = [
    for (final w in ActivationWorld.values)
      if (w.holds case final holds?)
        _check(
          cfg: w.cfg,
          world: w.spec,
          invariants: [for (final i in w.invariants) i.tla],
          expect: 'No error has been found',
          label: holds,
        ),
    for (final (:cfg, :spec, :label) in printed)
      _check(
        cfg: cfg,
        world: spec,
        invariants: [for (final i in invariantsOf(spec)) i.tla],
        expect: 'No error has been found',
        label: label,
      ),
    for (final x in Witness.values)
      _check(
        cfg: 'activation_reach_${x.name.toLowerCase()}',
        world: x.world.spec,
        invariants: [x.tla],
        expect: '${x.tla} is violated',
        label: x.doc,
      ),
    for (final m in Mutant.values)
      for (final (i, (world, spec, doc)) in [
        (m.world, m.spec, m.doc),
        for (final MapEntry(:key, :value) in m.also.entries)
          (key, key.spec, value),
      ].indexed)
        _check(
          cfg: 'activation_${m.name}${i == 0 ? '' : '_${_snake(world.name)}'}',
          world: spec,
          invariants: [m.by.tla],
          expect: '${m.by.tla} is violated',
          label: doc,
          mutant: m,
        ),
    for (final h in HandMistake.values)
      _check(
        cfg: 'activation_${h.name}',
        world: h.spec,
        mistake: h,
        invariants: switch (h.caught) {
          Breaks(:final inv) => [inv.tla],
          Deadlocks() => [Inv.typeOK.tla],
        },
        expect: switch (h.caught) {
          Breaks(:final inv) => '${inv.tla} is violated',
          Deadlocks() => 'Deadlock reached',
        },
        label: h.doc,
      ),
  ];
  assert(
    {for (final c in checks) c.cfg}.length == checks.length,
    'two checks print one config',
  );
  assert(
    ActivationWorld.values.every(
      (w) =>
          w.holds != null ||
          (HandMistake.values.any((h) => h.world == w) &&
              !Witness.values.any((x) => x.world == w) &&
              !Mutant.values.any((m) => m.world == w || m.also.containsKey(w))),
    ),
    'a world that holds nothing runs only a planted hand-written mistake',
  );
  return checks;
}

Check _check({
  required String cfg,
  required WorldSpec world,
  HandMistake? mistake,
  required List<String> invariants,
  required String expect,
  required String label,
  Mutant? mutant,
}) {
  assert(
    {for (final e in world.env) e.op}.length == world.env.length,
    '$cfg replaces one operator twice',
  );
  final text = [
    '\\* $label',
    'CONSTANTS',
    '    Containers = ${(world.cookies == Cookies.containers).tla}',
    '    ColdStart = ${world.coldStart.tla}',
    '    Mistake = "${mistake?.name ?? 'none'}"',
    '    MaxInputs = ${world.inputs}',
    '    Tabbed = {${world.tabbed.join(', ')}}',
    '    MaxTabs = ${world.maxTabs}',
    switch (world.allowed) {
      null => '    Allowed <- Inputs',
      final a => '    Allowed = {${[for (final x in a.toList()..sort()) '"$x"'].join(', ')}}',
    },
    for (final e in Env.values)
      if (world.env.contains(e)) '    ${e.op.tla} <- ${e.by}',
    'SPECIFICATION Spec',
    'VIEW View',
    'INVARIANTS',
    for (final i in invariants) '    $i',
    '',
  ].join('\n');
  return (
    cfg: cfg,
    world: world,
    text: text,
    expect: expect,
    label: label,
    mutant: mutant,
  );
}

extension on bool {
  String get tla => this ? 'TRUE' : 'FALSE';
}

String _upper(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

String _snake(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
