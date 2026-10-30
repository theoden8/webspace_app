import 'package:webspace/services/site_tab.dart';

/// What started a flow, as `fl[f].kind` names it.
enum FlowKind { tap, preload, home, pressure, tab, nested, wake, dns, space, close, delete, unload }

/// Every platform call a step may wait on, which a fake reports as it is
/// made (`pace`): a step declares its calls from here and a fake can only
/// report one of these, so neither side can name a call the other lacks.
enum PlatformCall {
  webViewClearCache('WebViewController.clearCache'),
  webViewSaveState('WebViewController.saveState'),
  webViewPause('WebViewController.pause'),
  webViewResume('WebViewController.resume'),
  webViewEvaluateJavascript('WebViewController.evaluateJavascript'),
  cookiesGet('CookieManager.getCookies'),
  cookiesGetAll('CookieManager.getAllCookies'),
  cookieSet('CookieManager.setCookie'),
  cookieDelete('CookieManager.deleteCookie'),
  cookiesDeleteAll('CookieManager.deleteAllCookies'),
  cookiesDeleteAllForUrl('CookieManager.deleteAllCookiesForUrl'),
  cookieStoreLoad('CookieSecureStorage.loadCookiesForSite'),
  cookieStoreSave('CookieSecureStorage.saveCookiesForSite'),
  cookieStoreRemoveOrphans('CookieSecureStorage.removeOrphanedCookies'),
  containerIsSupported('ContainerNative.isSupported'),
  containerGetOrCreate('ContainerNative.getOrCreateContainer'),
  containerDelete('ContainerNative.deleteContainer'),
  containerClearData('ContainerNative.clearContainerData'),
  containerList('ContainerNative.listContainers'),
  navStateSave('WebViewStateStorage.saveState'),
  navStateLoad('WebViewStateStorage.loadState'),
  navStateRemove('WebViewStateStorage.removeState'),
  navStateRemoveForSite('WebViewStateStorage.removeStatesForSite'),
  navStateRemoveOrphans('WebViewStateStorage.removeOrphans'),
  navStateSiteIds('WebViewStateStorage.siteIds'),
  routerSetRoutes('ProxyRouter.refreshRoutes'),
  proxyOverride('ProxyController.setProxyOverride'),
  nestedScreen('Navigator.push'),
  headlessOpen('HeadlessInAppWebView.run'),
  headlessClose('HeadlessInAppWebView.dispose'),
  wakeSettle('BackgroundWake.settle'),
  dnsFetch('DnsBlockService.fetchLevel'),
  connectivity('ConnectivityService.isOnline'),
  archiveSave('Archive.save'),
  archiveSeal('Archive.close'),
  siteSetCommit('PageHost.commitSites'),
  frame('SchedulerBinding.endOfFrame');

  const PlatformCall(this.label);

  /// `Interface.method`, as a log line names it.
  final String label;
}

/// The branch a step took, named as `formal/activation.tla` names it.
enum StepOutcome {
  none,
  empty,
  go,
  bail,
  clear,
  unload,
  skip,
  spared,
  disposed,
  queued,
  gone,
  capture,
  stale,
  cleared,
  kept,
  snap,
  save,
  more,
  nuke,
  end,
  others,
  commit,
  home,
  stay,
  busy,
  rebind,

  /// The platform refused the step's call (`Refused`).
  refused;

  /// The outcome in the model: `none` is the empty string.
  String get tla => this == none ? '' : name;
}

/// Why the page's pauses may be one step: they write nothing the model
/// holds, and the version they read between them only decides which pauses
/// still run, which the step's arms read again at its reply.
const _pauses = 'the pauses write nothing the model holds';

/// Why a site's cookies may be set in one step: the jar's turn is held
/// across the writes, so no flow reads the jar between them (ISO-003).
const _inTurn = 'the jar is written within one turn';

/// Why a wake's reloads, settle, reads and posts may be one step: they
/// write nothing the model holds, so an input landing between two of them
/// lands as well before the step or after it.
const _wakeMiddle = 'a wake\'s reloads, settle, reads and posts write '
    'nothing the model holds';

/// One step of an activation, a memory-pressure plan or an unload: what
/// runs between two awaits, as an action of `formal/activation.tla` (the
/// same name, capitalised). Each declares the branches it can take and the
/// platform calls it may wait on; a walk holds every call a flow makes to
/// the step it marks next, and replays the marks against the model
/// (`formal/trace/check_steps.sh`).
enum ActivationStep {
  tap(),
  goHome(),
  pressure(),

  /// A site off screen unloaded at a home reset (`unload(site)`): a plan of
  /// that one site.
  unloadSite(),
  move(),
  login(calls: {PlatformCall.cookieSet}),

  /// A site loaded off screen, a notification site at launch: an activation
  /// that does not show.
  preload(),

  /// The preload's saved navigation state is read.
  preloadNavReply(
    outcomes: {StepOutcome.go, StepOutcome.bail},
    calls: {PlatformCall.navStateLoad},
  ),

  /// The shared jar is emptied in a turn when no site is loaded, first at
  /// launch: what the last session left there is no site's (ISO-003).
  clearJar(calls: {PlatformCall.cookiesDeleteAll}),
  pressurePlan(
    outcomes: {StepOutcome.empty, StepOutcome.clear, StepOutcome.unload},
  ),
  navReply(
    outcomes: {StepOutcome.go, StepOutcome.bail},
    calls: {PlatformCall.navStateLoad},
  ),
  plan(),
  nextUnload(outcomes: {StepOutcome.unload, StepOutcome.skip}),

  /// The victim's webview answered its back stack capture; dropped when
  /// the site keeps none or the tab it was read for closed meanwhile.
  unloadNavReply(
    outcomes: {StepOutcome.go, StepOutcome.skip},
    calls: {PlatformCall.webViewSaveState},
  ),
  unloadNavSave(
    outcomes: {StepOutcome.none, StepOutcome.gone},
    calls: {PlatformCall.navStateSave},
  ),

  /// The victim's saved back stack removed again: its tab closed or moved
  /// while the save was out.
  unloadNavUnsave(calls: {PlatformCall.navStateRemove}),

  /// The capture over: the container path disposes here, the jar path
  /// waits for the jar's turn.
  unloadCaptured(
    outcomes: {
      StepOutcome.gone,
      StepOutcome.spared,
      StepOutcome.disposed,
      StepOutcome.queued,
    },
  ),
  grantUnload(
    outcomes: {
      StepOutcome.gone,
      StepOutcome.spared,
      StepOutcome.disposed,
      StepOutcome.capture,
    },
  ),
  unloadCapReply(
    outcomes: {StepOutcome.none, StepOutcome.refused},
    calls: {PlatformCall.cookiesGetAll},
  ),

  /// The capture could not read the jar: the site's stored set stays, and
  /// the unload goes on to its dispose (ISO-014).
  unloadKept(outcomes: {StepOutcome.spared, StepOutcome.disposed}),
  unloadSaveReply(
    outcomes: {StepOutcome.spared, StepOutcome.disposed},
    calls: {PlatformCall.cookieStoreSave},
  ),
  afterUnload(outcomes: {StepOutcome.stale, StepOutcome.go}),
  nextClear(outcomes: {StepOutcome.clear, StepOutcome.skip}),
  cacheReply(
    outcomes: {StepOutcome.cleared, StepOutcome.kept, StepOutcome.stale},
    calls: {PlatformCall.webViewClearCache},
  ),
  applied(),
  quiesceReply(
    outcomes: {StepOutcome.go, StepOutcome.bail},
    calls: {PlatformCall.webViewEvaluateJavascript, PlatformCall.webViewPause},
    severalAwaits: _pauses,
  ),
  grantRestore(
    outcomes: {StepOutcome.stale, StepOutcome.skip, StepOutcome.snap},
  ),
  restoreSnapReply(
    outcomes: {
      StepOutcome.stale,
      StepOutcome.save,
      StepOutcome.nuke,
      StepOutcome.refused,
    },
    calls: {PlatformCall.cookiesGetAll},
  ),
  restoreSaveReply(
    outcomes: {StepOutcome.stale, StepOutcome.more, StepOutcome.nuke},
    calls: {PlatformCall.cookieStoreSave},
  ),
  restoreNukeReply(
    outcomes: {StepOutcome.none, StepOutcome.refused},
    calls: {PlatformCall.cookiesDeleteAll},
  ),
  restoreLoadReply(calls: {PlatformCall.cookieStoreLoad}),
  restoreSetTargetReply(
    outcomes: {StepOutcome.end, StepOutcome.others, StepOutcome.refused},
    calls: {PlatformCall.cookieSet},
    severalAwaits: _inTurn,
  ),
  restoreSetOtherReply(
    outcomes: {StepOutcome.end, StepOutcome.more, StepOutcome.refused},
    calls: {PlatformCall.cookieSet},
    severalAwaits: _inTurn,
  ),

  /// A refill write the jar refused: the rest is still written, and the
  /// restore then fails (ISO-014).
  restoreRefused(outcomes: {StepOutcome.end, StepOutcome.more}),
  contReply(
    outcomes: {StepOutcome.commit, StepOutcome.gone, StepOutcome.bail},
    calls: {PlatformCall.containerGetOrCreate},
  ),

  /// The container a superseded activation made for a site no longer on
  /// the list deleted again (ARCH-014).
  contGoneReply(calls: {PlatformCall.containerDelete}),

  /// A shared proxy route repointed before the target loads (LIR-024).
  routesReply(
    outcomes: {StepOutcome.go, StepOutcome.bail},
    calls: {PlatformCall.routerSetRoutes},
  ),

  /// The site's cached or imported HTML decrypted before its webview builds.
  htmlReply(outcomes: {StepOutcome.go, StepOutcome.bail}),
  commit(outcomes: {StepOutcome.none, StepOutcome.bail}),
  resumeReply(calls: {PlatformCall.webViewResume}),
  exit(outcomes: {StepOutcome.home, StepOutcome.stay, StepOutcome.refused}),

  /// The site left's webview answered its back stack capture; dropped
  /// when the tab it was read for closed meanwhile.
  homeCapture(
    outcomes: {StepOutcome.go, StepOutcome.skip},
    calls: {PlatformCall.webViewSaveState},
  ),
  homeCaptureSave(
    outcomes: {StepOutcome.none, StepOutcome.gone},
    calls: {PlatformCall.navStateSave},
  ),

  /// The site left's saved back stack removed again: its tab closed or
  /// moved while the save was out.
  homeCaptureUnsave(calls: {PlatformCall.navStateRemove}),

  /// Going home's page stop and pause, after its capture.
  homeQuiesceReply(
    calls: {PlatformCall.webViewEvaluateJavascript, PlatformCall.webViewPause},
    severalAwaits: _pauses,
  ),

  /// A link opens nested as a site (LIR-011, LIR-015): a screen that runs
  /// as it beside the loaded sites, one at a time.
  nestedOpen(),

  /// The webspace that shows the target, for an open from outside a site.
  nestedSwitchReply(),

  /// Which running sites the screen would repoint, asked again after every
  /// round of unloads; a newer input supersedes the open.
  nestedAsk(
    outcomes: {StepOutcome.stale, StepOutcome.unload, StepOutcome.go, StepOutcome.skip},
  ),

  /// The process-wide proxy moved to the target's route.
  nestedApplyReply(
    outcomes: {StepOutcome.bail, StepOutcome.stale, StepOutcome.unload, StepOutcome.go},
    calls: {PlatformCall.proxyOverride},
  ),

  /// The screen popped: the open ends, or goes on as the activation of the
  /// site on screen, which it unloaded.
  nestedPop(
    outcomes: {StepOutcome.end, StepOutcome.go},
    calls: {PlatformCall.nestedScreen},
  ),

  /// A webspace chosen on the list (WEBSPACE-013), and the device's answer
  /// to whether it is online, on which the switch plans its unloads.
  spaceSwitch(),
  spaceOnlineReply(
    outcomes: {StepOutcome.stale, StepOutcome.skip, StepOutcome.go},
    calls: {PlatformCall.connectivity},
  ),

  /// The site the switch superseded the opening of goes on loading off
  /// screen, as a preload does, started in the switch's turn.
  spaceKeep(),

  /// The OS wakes the app in the background to check its notification
  /// sites (NOTIF-016): the ones with no webview are its to check headless.
  wake(),

  /// The app leaves the screen, or comes back to it: a wake's checks close
  /// at once, in the proxy rule's turn (ProcessRoute.vacateEvery).
  background(),
  foreground(),

  /// Whether a notification site may be checked beside what runs (the
  /// activation's RouteFree, and no activation in flight); one that may
  /// claims its place first.
  wakeAsk(outcomes: {StepOutcome.skip, StepOutcome.go}),

  /// The route the check runs on is in force, or could not be.
  wakeApplyReply(
    outcomes: {StepOutcome.bail, StepOutcome.go},
    calls: {PlatformCall.proxyOverride},
  ),

  /// The headless webview is up and loading, or was refused.
  wakeOpenReply(
    outcomes: {StepOutcome.go, StepOutcome.skip},
    calls: {PlatformCall.headlessOpen},
  ),

  /// The live sites reloaded, every check settled, titles read and the
  /// fallback posts made (NOTIF-013, NOTIF-014).
  wakeMiddle(
    outcomes: {StepOutcome.end, StepOutcome.go},
    calls: {PlatformCall.wakeSettle},
    severalAwaits: _wakeMiddle,
  ),

  /// One check disposed and gone from the rule; the last ends the wake.
  wakeCloseReply(
    outcomes: {StepOutcome.end, StepOutcome.more},
    calls: {PlatformCall.headlessClose},
  ),

  /// A DNS level's list asked for (DnsBlockService, DNS-019, DNS-021): as
  /// the app-wide level, or as one more a site may run at.
  dnsDownload(),
  dnsAddLevel(outcomes: {StepOutcome.skip, StepOutcome.go}),

  /// The list fetched and folded in, or not had: on the fold the partition
  /// and the app-wide level are in force together, and each live view is
  /// told its site's level (DNS-022).
  dnsFolded(
    outcomes: {StepOutcome.go, StepOutcome.bail},
    calls: {PlatformCall.dnsFetch},
  ),

  /// DNS blocking turned off (level 0), and its lists deleted: then off is
  /// in force and every live view is told it.
  dnsClear(),
  dnsCleared(),

  /// A site's webview is built and attaches at its site's level, or is
  /// gone: the environment's, as a frame builds or drops it.
  viewBuilt(),
  viewGone(),

  /// A frame mounts a loaded site's webview, which binds its container, or
  /// unmounts one whose site is not loaded: the environment's.
  frame(),

  /// An open archive closed (ArchiveController.close, ARCH-007, ARCH-014):
  /// refused with nothing changed when its sealed state does not fit its
  /// slot (ARCH-011), else sealed and saved with its key zeroed, its sites
  /// off the lists, their webviews gone with the next frame, then their
  /// containers and every per-site trace outside the archive.
  closeArchive(outcomes: {StepOutcome.skip, StepOutcome.go}),
  closeSealReply(
    calls: {PlatformCall.archiveSave, PlatformCall.archiveSeal},
    severalAwaits: "the sealed state saved, then the key zeroed: neither is "
        'anything the model holds',
  ),
  closeDropReply(calls: {PlatformCall.siteSetCommit}),
  closeFrameReply(calls: {PlatformCall.frame}),
  closeDeleteReply(
    calls: {PlatformCall.containerDelete},
    severalAwaits: "one container per site of the archive, which nothing "
        'between two can bind again: their sites are off the lists and '
        'their webviews gone',
  ),
  closeEraseReply(
    calls: {
      PlatformCall.containerDelete,
      PlatformCall.navStateRemoveForSite,
      PlatformCall.cookieStoreSave,
    },
    severalAwaits: 'the per-site traces outside the archive, none of which '
        'the model holds',
  ),

  /// A site deleted (SiteDeletion, ARCH-014's order): off the lists in the
  /// page's commit, its webview gone with the next frame, then its
  /// container, and on the shared jar its cookies, which the walk's delete
  /// world, on containers, does not take.
  deleteSite(),
  deleteDropReply(calls: {PlatformCall.siteSetCommit}),
  deleteFrameReply(calls: {PlatformCall.frame}),
  deleteRetireReply(calls: {PlatformCall.containerDelete}),

  /// A tab handler's input (TabsController), after its synchronous
  /// prelude; dropped while another holds the tab gate. Its mark names
  /// the tab it picked, so a replay can tell the flows apart.
  openTab(outcomes: {StepOutcome.go, StepOutcome.busy, StepOutcome.stay}),
  newTab(outcomes: {StepOutcome.go, StepOutcome.busy}),
  closeTab(outcomes: {StepOutcome.go, StepOutcome.busy}),
  duplicateTab(outcomes: {StepOutcome.go, StepOutcome.busy}),

  /// The tab being left: its webview answered its back stack capture, to
  /// be saved under the webview's tab; nothing when the target tab left
  /// the list, or the capture's tab did.
  tabCaptureReply(
    outcomes: {StepOutcome.go, StepOutcome.gone, StepOutcome.skip},
    calls: {PlatformCall.webViewSaveState},
  ),
  /// Its back stack saved: the tab gate keeps every other tab handler out
  /// meanwhile (`Inv_OneTabFlow`), so the tab is still where it was keyed.
  tabCaptureSave(
    outcomes: {StepOutcome.none},
    calls: {PlatformCall.navStateSave},
  ),

  /// The target tab's saved back stack read.
  tabNavReply(
    outcomes: {StepOutcome.go, StepOutcome.gone},
    calls: {PlatformCall.navStateLoad},
  ),

  /// List, pointer and webview move in one turn; a target that runs as
  /// another site under one process-wide proxy takes the slot out of the
  /// loaded sites in it (LIR-024).
  tabRebind(outcomes: {StepOutcome.none, StepOutcome.unload}),

  /// A close decided: the list installed, or a rebind to the tab that
  /// takes over.
  tabClosed(outcomes: {StepOutcome.end, StepOutcome.rebind}),

  /// A closed tab's saved back stack removed, once no list holds it.
  tabRemoveReply(
    outcomes: {StepOutcome.more, StepOutcome.end},
    calls: {PlatformCall.navStateRemove},
  ),

  /// The duplicate's source read: the webview when loaded, else its file.
  dupReadReply(
    outcomes: {StepOutcome.save, StepOutcome.skip},
    calls: {PlatformCall.webViewSaveState, PlatformCall.navStateLoad},
  ),
  dupSaveReply(calls: {PlatformCall.navStateSave}),

  /// The copy joins the list, or is dropped with its source gone.
  dupInsert(outcomes: {StepOutcome.go, StepOutcome.gone}),
  dupRemoveReply(calls: {PlatformCall.navStateRemove}),

  /// A site's routing switch flipped as its settings closed (LIR-034): the
  /// link tabs it opened in its own tree are to run as the site their link
  /// leads to, or as it again.
  reroute(outcomes: {StepOutcome.go, StepOutcome.busy}),

  /// A reset lands a site with tabs at home (TAB-014); dropped while a tab
  /// handler runs.
  homeLanding(outcomes: {StepOutcome.go, StepOutcome.busy}),

  /// A slot that runs as another site, or on a tab anchored in another
  /// domain, moves to a tab its site runs itself before an owner URL loads
  /// (LIR-018, LIR-034); it waits for a free gate, so it is never dropped.
  ownerRun(outcomes: {StepOutcome.go}),

  /// The tab the landing names: the one the site is on already, a loaded
  /// site's switch to it, or the pointer moved for a site with no webview.
  homeLand(outcomes: {StepOutcome.stay, StepOutcome.rebind, StepOutcome.go}),

  /// The tab an owner-run move names, taken as a landing's is.
  ownerLand(outcomes: {StepOutcome.stay, StepOutcome.rebind, StepOutcome.go}),

  /// A link or a search opens a child tab of a site with tabs and switches
  /// to it (LIR-030, LIR-032); dropped while a tab handler runs.
  childTab(outcomes: {StepOutcome.go, StepOutcome.busy}),

  /// A long-pressed link or Back opens a parked child tab (TAB-006,
  /// TAB-020); it waits for a free gate, so it is never dropped.
  parkChild(outcomes: {StepOutcome.go}),

  /// The child joins its site's list, running as the site it was opened
  /// for, and the switch to it begins.
  childLand(outcomes: {StepOutcome.go}),

  /// The listed child's switch begins, from a step of its own: the
  /// capture reads at its start what the child's insert wrote.
  childOpen(outcomes: {StepOutcome.none}),

  /// The parked child joins its site's list, and the page offers it.
  parkLand(outcomes: {StepOutcome.go}),

  /// The reroute's flips, in its input's turn. The tab on screen moves its
  /// slot to the other site at once: under one process-wide proxy the slot
  /// leaves the loaded sites and opens again (LIR-024), else its webview is
  /// built again.
  rerouteFlip(outcomes: {StepOutcome.none, StepOutcome.unload, StepOutcome.rebind}),

  /// A flipped tab's saved back stack, the transcript of the site it left,
  /// removed; the last removal ends the reroute.
  rerouteRemoveReply(
    outcomes: {StepOutcome.more, StepOutcome.end},
    calls: {PlatformCall.navStateRemove},
  );

  const ActivationStep({
    this.outcomes = const {StepOutcome.none},
    this.calls = const {},
    this.severalAwaits,
  });

  final Set<StepOutcome> outcomes;

  /// The platform calls the step may wait on.
  final Set<PlatformCall> calls;

  /// Why the step may wait on more than one call before it lands, when it
  /// does: the model takes a step whole, so a check between two awaits is
  /// one it cannot see. Null means one await at most, which the walks hold
  /// every step to.
  final String? severalAwaits;

  /// The model's action for the step.
  String get action => '${name[0].toUpperCase()}${name.substring(1)}';
}

/// Where the steps are marked. Nothing listens outside a test, which sets
/// [sink] for one world at a time. A step's site is the engine's own value
/// for it (a `WebViewModel`), untyped here so this file sits below the model
/// layer; a step that picked a tab marks it too, so a replay can tell the
/// picks apart.
abstract final class ActivationSteps {
  static void Function(
    ActivationStep step, {
    required StepOutcome outcome,
    required Object? site,
    required TabId? tab,
  })?
  sink;

  static void mark(
    ActivationStep step, {
    StepOutcome outcome = StepOutcome.none,
    Object? site,
    TabId? tab,
  }) {
    assert(
      step.outcomes.contains(outcome),
      '$step cannot end as $outcome; formal/activation.tla says which can',
    );
    sink?.call(step, outcome: outcome, site: site, tab: tab);
  }
}
