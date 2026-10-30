# BUG-037 — A site loaded in the background runs on another site's proxy

Status: open

**Spec:** [proxy](../../openspec/specs/proxy/spec.md) PROXY-008 ("Android —
no background load on another route"), [web-push-notifications](../../openspec/specs/web-push-notifications/spec.md)
NOTIF-016, NOTIF-017
**Model:** [formal/activation.tla](../../formal/activation.tla)
(`Inv_OneRoute` under `activation_proxy.cfg`, its containers twin, the
router's and the Tor config; the `preloadmismatch` mistake is the preload's
guard without the route check, and TLC breaks it under the proxy and the Tor
configs)
**Tests:** [test/activation_schedules_test.dart](../../test/activation_schedules_test.dart)
(every schedule of the launches with mismatched proxies, the router's shared
session and two Tor exits), [test/site_unload_engine_test.dart](../../test/site_unload_engine_test.dart)

## Symptom

On Android without per-site profiles (and, before attempt 22, outside
router mode), a site's requests leave through another
site's proxy: the user configured proxy P1 for one site and P2 for a
notification site, opened the first, and the notification site loaded at
launch. Building its webview set P2 as the process-wide override, so the
site on screen ran on P2. The same holds for two Tor sites pinned to
different exit countries: the one Tor runtime takes the last pin.

## Root mechanism / invariant

On Android one `ProxyController.setProxyOverride` covers every webview in
the process, and one Tor runtime has one `ExitNodes`. Loaded sites in one
proxy scope must therefore share one route, and loaded Tor sites one exit
(PROXY-008, TOR-025). An activation keeps this by unloading the sites on
another route before it builds its webview. Any load that does not run an
activation's plan skips that, and a webview built on another route moves
the override under the sites already loaded.

## Fix attempts

1. **2026-04-30, #262 (`318fbf25`).** `SiteUnloadEngine`'s activation plan
   unloads loaded sites whose effective proxy differs before the override
   flips (`indicesToUnloadForProxyMismatch`); #272 then dropped the
   save-time mirror that had copied one proxy into every site.
   *Why:* Android cannot scope a proxy per webview, so sites on different
   proxies must not be loaded together. *Partial:* it held for an
   activation only. The launch's auto-load of notification sites, added
   later (#423, `d6bb960c`), marked them loaded with no plan and no check.
2. **2026-09-24, #619 (`1e8274a4`).** The plan also unloads Tor sites
   pinned to another exit country. *Why:* the Tor runtime's exit pin is
   process-wide as well. *Partial:* the same path, an activation only.
3. **2026-10-07, #675 (`97304131`).** A background wake's headless check
   skips a site whose route differs from the one the wake runs under
   (`WakeSkip.proxyConflict`). *Why:* the headless webview is built with
   the site's posture, which applies its proxy. *Partial:* the wake only;
   the launch's auto-load still loaded without a check.
4. **2026-10-13, PR #696.** The launch's auto-load is a preload (an
   activation that does not show), and its guard takes `RouteFree` from the
   unload engine's printed `ProxyContenders` and `TorDissenters`: a
   notification site on another route waits until the user opens it, whose
   activation unloads the others first. `Inv_OneRoute` states the rule from
   the definitions, not from the guard, and the `preloadmismatch` mutant
   (the guard without the check) is caught. *Why:* every load the model
   holds is now an activation or a preload, so the check is the plan's
   definitions in both. *Partial:* the nested open, the settings save and
   the wake still wrote the rule outside it.
5. **2026-10-13, PR #696.** One owner of the rule, `ProcessRoute`: every
   write is a claim in its turn by what will run on it (a site's webview,
   a nested screen, a wake's check), released when that goes, and a debug
   build asserts nothing else running needs another route. Its first use
   found two more paths. The nested open fixed its mismatched set before
   its unload awaits, so a site that loaded meanwhile ran under the new
   proxy; it now asks again after every unload and stands down when a tap
   superseded it. A settings save moved the rule at once for the edited
   site, live or not, under sites still on the old route; it now runs the
   residency plan first, and only a live webview takes the rule. The
   writes, which await the relay before the override, now take turns.
   *Why:* a fact with three writers and no owner; the owner makes each
   writer say what runs on the rule. *Partial:* the nested open's fix was
   one engine's loop, which no model held, and a launch preload still did
   not see a nested screen.
6. **2026-10-13, PR #696.** The nested open is a flow of the activation
   table (`openNested`), and the proxy rules range over the running sites,
   the loaded ones and the one a nested screen runs as (`Running`), so the
   preload's check, the plan's and `Inv_OneRoute` all see the screen. TLC
   then found four more paths. A tap in flight committed beside the
   screen, which never superseded it: a nested open now supersedes the
   activation in flight as a tap does. A tap during the open's unloads had
   its site disposed, since only a tap's unloads backed off: the open's back
   off too. An open that unloaded the site on screen left it blank after
   the pop, inbound or outbound: the flow goes on as that site's
   activation. A nested screen for a Tor site went straight up beside a
   loaded Tor site on another exit: the open now checks the exit whatever
   the proxy scope, and pins it. A preload asks again at its commit.
   `nestedonce` and `preloadunchecked` are the shapes before, caught.
   *Why:* the open's steps were outside every model, so its races were
   found one at a time. *Partial:* see below.
7. **2026-10-13, PR #696.** A nested open whose proxy moved, then found a
   site loaded on another route, went back to unload it still holding its
   claim on the rule; an input that superseded it during that round ended
   the flow with the claim never released, so the next write of the rule
   failed `ProcessRoute`'s assert. The claim now goes with the round, and
   the walks claim through a `ProcessRoute` of their own and require it
   empty once settled. *Why:* the claim was released only where the screen
   was known gone, not on every way out. *Partial:* the model holds which
   sites run, not where the rule points, so a claim left behind is caught
   by the walks only.
8. **2026-10-13, PR #696.** A background wake took the route in force from
   the live notification sites alone. With the site the user left on screen
   loaded and its notifications off, and a notification site on another
   proxy or Tor exit with no webview, the wake applied the headless site's
   route under the live one, and nothing put it back: on return the site
   on screen ran through the other proxy or exit. The plan now takes the
   route in force from every live site (`BackgroundWakeEngine.plan`), with
   two engine tests. *Why:* the plan read the wake's own candidates, not
   what runs. *Partial:* the wake is still outside the model; a loaded site
   whose webview builds during a wake claims the rule under its checks,
   which only `ProcessRoute`'s assert sees.
9. **2026-10-13, PR #696.** Back in the foreground during a wake, the
   checks were released from the rule before they were disposed, one after
   another, so a site the user opened meanwhile could move the proxy under
   a check still loading. A check now leaves the rule once disposed, in the
   rule's turn (`ProcessRoute.vacate`), and a write asked for meanwhile
   waits for it, with a boundary test. *Why:* the release was bookkeeping,
   not a turn of the rule. *Partial:* the wake is still outside the model.

10. **2026-10-13, PR #696.** The background wake is a step table the
   model prints (`WakeTable`), and its headless checks are running sites
   (`headless` in `Running`), so a check asks the activation's own
   `RouteFree` before it claims its place, and a preload sees a check as
   it sees a loaded site. The app's lifecycle is the table's `Background`
   and `Foreground` inputs (`fore`), one wake at a time, and a wake asked
   for while one runs joins it. TLC then found a check that went up beside
   a tap still in flight from before the app left the screen: the tap's
   plan had run before the check existed, and its commit put a site on
   another route beside it. A check now passes over every site while an
   activation is in flight, as a preload does (`activationInFlight`). The
   walks then found a check whose claim was queued just before the app's
   return: the return took its list of checks at the call, so the claim
   stayed on the rule with nothing running on it, and the next site the
   user opened failed the rule's assert. The return now takes every check
   in the rule's turn, after any open still under way has ended
   (`ProcessRoute.vacateEvery`), and a check that never opens drops its
   claim at once. `wakeunchecked` (the ask without the rule) and
   `wakebesidetap` (the ask without the activation in flight) are caught.
   *Why:* the wake's rule was its own (`wakeRouteFor`), outside every
   model. *Partial:* the model's `Foreground` empties `headless` at once,
   while the code holds the rule's turn until the opens end; a write that
   waits for that turn is held by `ProcessRoute`, not by the model.

11. **2026-10-13, PR #696.** A claim took its occupant off the rule as it
   began and put it back once its write returned, so a webview disposed
   while its write was out came back as an occupant on the route it was
   leaving, and the next site's claim on another route failed the assert.
   The rule now remembers whose write is out, and a release during it
   leaves the occupant off (`ProcessRoute._writing`); a failed write leaves
   no claim behind. *Why:* the walks drive the nested open's and the
   wake's claims, whose releases come only after their writes or in the
   rule's turn; a webview's claim, made as its controller arrives, is in no
   walk. *Partial:* the webview's claim is still outside the model and the
   walks.

12. **2026-10-13, PR #696.** The rule's claims, turns and releases as a
   model of their own (`formal/process_route.tla`) found attempt 11
   partial: a release that lands while the claim still waits for the turn
   cleared nothing, since nothing was out yet, and the write then ran and
   listed the occupant. Each claim now takes a ticket as it is made; a
   release voids it, so a claim released before its turn writes nothing
   and one released during its write is not listed after it, and a claim
   made again replaces the old ticket. The walks claim on every webview
   they build under a global rule and hold the occupants to the loaded
   sites at settle. Mutants caught: `readd` (the write lists its occupant
   whatever the ticket), `midwrite` (no ticket on the write in flight),
   `noturn` (two writes out at once). *Why:* attempt 11 reasoned about
   the write in flight and not the queue before it; a model with both
   found the gap in one step. *Partial:* the model is standalone; the
   activation's model still holds which sites run, not the route each
   write sets.
13. **2026-10-14, PR #696.** A slot's running identity moved before its
   webview went. The routing reconcile (LIR-034) and a tab switch onto a
   tab that runs as another site (LIR-024) rewrote the identity first and
   disposed the webview after an await (the reconcile's state removals, the
   switch's reroute plan). A plan in that window read the new identity's
   route for a webview still on the old one, so a tap there left a site on
   the old route loaded beside the new one and the rule moved under it.
   Now the identity and the webview change in one turn: under one
   process-wide proxy the slot leaves the loaded sites in that turn, and
   when it is on screen, or the target of an activation planned for the
   identity it left, its activation starts again in the same turn and
   runs PROXY-008 for the new identity, superseding the old plan; the
   switch's separate reroute step is gone. Found by the reroute world of
   the schedules (a link tab that follows its opener, under mismatched
   proxies). Mistakes planted and caught: the old order, a reopen of the
   screen's slot only (a tap in flight commits the old plan), a switch
   that reroutes nothing, and an activation started after the turn.
   *Why:* one fact, the active tab's host, was read both as what to plan
   for and as what runs, and the two diverged across an await. *Partial:*
   the reroute world is held by the schedules alone; the model's `Route`
   is per site, so `activation.tla` takes no slot identity yet.
14. **2026-10-15, PR #696.** A wake's check opened beside a nested open
   in flight. Attempt 10's check waited out an activation by its marker,
   and a nested open sets none: its screen not yet up, the check of a
   notification site on another route passed `RouteFree`, and the pop
   that followed brought the site on screen back on its own route beside
   the check. Now a check also waits out a nested open in flight
   (`BackgroundWakeHost.nestedOpening`, the model's `"nested"` in flight)
   and is skipped as an activation in flight. Found by a world the
   printer made for a pair no written world took together (the nested
   open and the wake's ask, in containers with two routes); the world is
   now written (`activation_nested_wake_containers.cfg`) and the old guard
   is planted as `wakebesidenested`, caught by `Inv_OneRoute`. *Why:*
   attempt 10 read "an activation in flight" as the marker, which a
   nested open does not set, and no written world had links and wakes
   together, so TLC never ran the two side by side. *Partial:* the
   guard still names each kind of flow it waits for; a new kind that
   moves the route is caught once a printed world takes it beside the
   wake, not where the guard is written.
15. **2026-10-15, PR #696.** Attempt 13's reopen was code the tab table
   did not print. The rebind's unload arm called `_reopen` from inside its
   act, so the printed `TabRebind` took the slot out of `loaded` and
   started nothing, and any world with a tabbed site on a routed slot broke
   `Inv_ShownLoaded`. The printer held those worlds back as a gap of the
   model (`_modelGaps`), and `RoutesReply`/`TabRebind` stayed footprint
   debt. Now a step table declares an input it starts in its own turn
   (`Spawn`), with the input's step (`Tap`), the site it picks and the
   condition it starts under (`_reopened`: the site is on screen or the
   marker's target, the one owner `_reopen` reads too). The runner starts
   it after the arm's other effects and the step's mark, and asserts that
   the input landed once. An input that lands in a step's turn any other
   way fails an assert, so the code cannot start a flow the model does not
   print. The printer prints the input's effects in the same action, on the
   flow numbered next (`Starts`, which `Input` now uses too), over the
   state the arm leaves. The guard's model reading gained `Containers`
   (only containers let a tab run as another site): on the shared jar the
   printed arm dropped a signed-in session, which the code cannot reach.
   The gap list is gone, the routed tabs world is written
   (`activation_tabs_router_containers.cfg`, witness `Reach_Reopened`), and
   the arm without its spawn is planted as `noreopen`, caught by
   `Inv_ShownLoaded`. `RoutesReply`/`TabRebind` leaves the footprint debt,
   and so does `SpaceOnlineReply`/`TabRebind`: the spawn's version bump
   meets the webspace switch, and a written tabs world that reaches the
   list by going home (`activation_tabs_spaces.cfg`) takes all three.
   *Why:* the reopen was a side effect inside an act's
   code, which the printer does not read. *Partial:* the printed guard
   (`Containers /\ site \in Routed`) still stands in for "the target tab
   runs as another site under one process-wide proxy". The model keeps no
   slot identity, so the reroute world's traces are not replayed and
   `TabRebind unload` stays in `steps_uncovered.tsv`. A behavior that would
   start a flow past the last input ends there (`Done`).
16. **2026-10-22, PR #766.** The model kept no slot identity, so the
   reroute was checked by the schedules alone and `Routed` stood in for
   "the target tab runs as another site". Now the model holds which site
   each tab runs as (`host`, `SiteTab.hostCell`) and the site a link tab
   runs as while its owner routes links (`link`, `SiteTab.openerCell`,
   from the constant `Links`); `RunsAs(s)` is the active tab's host, a
   `Def` in `TabVars`. The proxy and Tor rules read each running slot
   through it (`ProxyContenders(s, a)`, `TorDissenters(s, a)`, with `a`
   the identity the target runs as), and `Inv_OneRoute` is stated over
   the identities that run. A tab's saved back stack is keyed by the
   identity it ran as (`file[s][t][h]`, as `webViewStateKey` keys it):
   a capture and a staged read record the identity at their start
   (`capAs`, `navAs`) and hold only while the tab still runs as it. The
   reconcile is a flow of the tab table: the input `Reroute` flips one
   owner's link tabs (`RerouteFlip`: unload under the process-wide proxy,
   with the reopen spawned as attempt 15's, rebind otherwise) and drops
   each flipped tab's file under the identity it left
   (`RerouteRemoveReply`). `_identityChanges` is exact, so `Routed` and
   `HandPaired.routedSite` are gone, the reroute world's traces replay,
   and the schedules owe no unmodelled meets. A tab runs as another site
   only after a reroute now, so attempt 15's `Reach_Reopened` and
   `noreopen` move to the reroute world
   (`activation_tabs_reroute_containers.cfg`), which takes four inputs: a
   switch onto a rerouted tab reopens the slot as the fourth. Planted: a
   reroute that rebinds in place under the process-wide proxy
   (`rerouteinplace`), caught by `Inv_OneRoute` in the model and by
   `ProcessRoute`'s assert under the schedules. *Why:*
   the identity was one fact the code held and the model did not, so the
   check of the switch that moves it could only be the walks.
   *Partial:* only the case the reconcile reaches from one owner's own
   links is a step; a link whose opener is not its owner, or a flip
   across several owners, still writes through
   `Commit.unmodeled(Unmodeled.identityChange)`.
17. **2026-10-23, #775 (`f548d5b5`).** A webview the app let go of went on
   sending until the plugin destroyed it, after it had loaded
   `about:blank`; on the emulator its icon fetch left through the next
   site's proxy once the override had moved. Now a site keeps its place on
   the rule until its webview has been told to block network loads
   (`ProcessRoute.leave(quiet:)`, `WebViewController.blockNetworkLoads`),
   in the rule's turn, so the next claim waits; a nested screen and a
   wake's headless check do the same, and a popup blocks and closes with
   its opener. *Why:* dropping the controller ended the app's hold on the
   webview, not the webview's traffic. *Partial:* Chromium applies
   `blockNetworkLoads` to a request once, as its interception starts
   (`LOAD_ONLY_FROM_CACHE` before `ShouldInterceptRequestAsync`); a request
   already past that point still went out. CI's Build Android run
   40097824430 caught one: the old site's `favicon.ico` reached the next
   site's upstream 0.6 ms after that site's first document request, both
   held until the new override took effect.
18. **2026-10-24, branch `claude/proxy-008-quiet-in-flight`.** The quiet
   also ends what the webview already started: `blockNetworkLoads` is now
   `WebViewController.quiet`, which marks the settings blocked and then
   calls `stopLoading` (`WebContents::Stop`), so the renderer cancels its
   loads, their pipes close, and the interceptor drops a request still
   waiting there. A popup quiets the same way before it closes, a nested
   screen through `NestedScreenWebView.quiet`, and a wake's headless check
   stops loading in its `dispose` before the rule's `vacate` lets the next
   claim run. The block comes first, so nothing the stop's teardown starts
   gets past it. *Why:* a block reaches only what is not yet intercepted,
   so a request in flight needs a cancel. *Partial:* see the gaps below:
   the cancel is asynchronous, and Dart has no signal to await for it.

19. **2026-10-24, the child-tab PR.** A slot's reopen ran beside its own
   nested screen. A world the printer made for the child tab's landing
   beside the nested open's apply, under one process-wide proxy on two
   routes, found it: site 1 opens a nested screen, a child tab that runs as
   site 3 lands and is switched to, the rebind takes the slot out of the
   loaded sites (attempt 13), and the reopen spawned in that turn (attempt
   15) committed site 1 as site 3 beside the screen, which runs as site 1.
   The rules read every running webview through `RunsAs` and skipped the
   site asked about (`t # s`). A nested screen and a wake's check run as
   their own site (`NestedOpening`, `headlessCheckConfig`), so the screen
   of a site whose active tab ran as another site read as that site, and
   the site's own slot was hidden from its screen's check. Now each rule
   takes only the site the asking webview runs as (`ProxyContenders(a)`,
   `TorDissenters(a)`, `RouteFree(a)`), and reads a loaded slot through
   `RunsAs` and a page (`Pages`: a nested screen, a wake's checks) as
   itself. A slot's activation asks for `RunsAs(s)`, a nested open and a
   wake's check for their own site. A plan's rules name loaded sites only
   (`Ruled`), and the reopen waits while a nested screen is up (`Reopens`),
   whose pop opens the site on screen as its activation. `Inv_OneRoute`
   read a wake's check through `RunsAs` as well, and now reads it as its
   site. The code's `identities(except:)`, which made a nested open read
   its own slot as itself, is gone. Planted and caught:
   `reopenbesidenested` (the reopen without the nested screen) and
   `screenskipsslot` (the rule skipping the asking site's own slot), by
   `Inv_OneRoute` in `activation_tabs_child_nested_containers.cfg` and by
   the route asserts under the schedules. *Why:* one set of running sites,
   each read through its slot's identity, could not hold a site's slot and
   its screen apart; and the reroute worlds' input bound hid the reopen
   beside the screen, since a reroute needs four inputs to reach it and a
   child tab three. *Partial:* a page is read as its own site because the
   code builds it so; a nested screen opened from a tab that runs as
   another site still runs as the site whose slot it is, which the spec
   does not decide.
20. **2026-10-25, branch `claude/tor-identity-change`.** A slot that ran
   as another site stayed loaded unless one process-wide proxy was in
   force: a tab switch's rebind and a reroute's flip took the slot out of
   the loaded sites only then (`TabTable._identityChanges`, attempt 13), so
   its webview was built again on its new route beside sites on the old
   one. Two rules other sites share were missed. Under a Tor runtime the
   one `ExitNodes` moved, until the commit's Tor sync unloaded the sites
   on the old exit outside any step. Under the router a slot could move
   into the shared default session; the world printed for the new reads
   found it: site 3's tap is in flight, site 1's child tab runs as site 2
   outside the session, the tap's plan reads the slot as site 2 and
   unloads nothing, a reroute flips the tab back to site 1, and the tap
   commits site 3 on route 2 beside site 1 on route 1, both in the
   session. Now both arms ask `MovesRule(a, b)`, a definition of the tab
   table: the slot's old or new identity contends (every site under one
   process-wide proxy, the session's under the router), or a Tor runtime
   exists. The code's flips outside a step read the same per site
   (`TabCalls.movesRule`). The commit's Tor sync no longer lets a site on
   screen but not loaded decide the pin (`SiteUnloadEngine.torSyncOrder`):
   that site waits for its activation, which would otherwise find the
   sites on the old exit already gone. The walk now holds `Inv_OneRoute`'s
   Tor half after every step, and records the sync's unloads as a
   violation instead of stopping at them. Planted and caught:
   `torkeepsslot` (`MovesRule` without the Tor runtime), by `Inv_OneRoute`
   in `activation_tabs_child_nested_tor_containers.cfg` and
   `activation_tabs_reroute_tor_containers.cfg` and by the walk's Tor
   half; `sessionkeepsslot` (`MovesRule` as one process-wide proxy), by
   `Inv_OneRoute` in `activation_tabs_reroute_router_containers.cfg` and
   the route assert under the schedules. *Why:* the arms named one proxy
   override where the rule they need is any route another running site
   shares. A settings change of a loaded site's proxy or Tor exit plans
   `SlotIdentityChanged` before the webview takes the new route; that plan
   now unloads the exit's dissenters too, where it unloaded only the
   proxy's contenders and left the rest to the commit's Tor sync.
   *Partial:* the model takes no settings change, since a site's route and
   exit are its constants (`Route`, `TorExit`).
21. **2026-10-26, branch `claude/router-decided`.** The gap "turning router
   mode off with sites on different routes loaded" had a path after all.
   The router decides at the launch, which binds the relay as the rule
   and then waits for its proof (PROXY-015), and the grid takes taps
   meanwhile. The residency plan read router mode from
   `ProxyRouterService.isActive`, true as soon as the relay was bound, so
   two sites tapped on different proxies stayed loaded side by side. A
   proof that failed then stood the relay down with both under one rule,
   pointed at a stopped port: two routes running on one rule, which
   `Inv_OneRoute` and `ProcessRoute`'s assert rule out. The launch's own
   activation, which would have unloaded one, is skipped once a tap
   activated. Now residency reads `routesPerSite`, true only once the
   launch's proof has passed (the topology, the wake's view of the rule,
   the notification switch's conflict). Before that a tap unloads the
   other route as under PROXY-008. The stand-down is private to `activate`, asserting it never
   follows a proof. *Why:* the topology moves only one way over a run,
   from every site contending to the router's shared session, and a
   weaker rule keeps what a stronger one planned. *Partial:* the model
   still holds the topology as a constant per world, and the order is
   checked by `proxy_router_service_test`'s two BUG-037 cases, each
   caught reading `routesPerSite` as `isActive`.
22. **2026-10-30, branch `claude/clever-tesla-vuke6m`.** The router is now
   the only way Android carries a proxy where the WebView reports
   `MULTI_PROFILE`, so the topology no longer moves over a run: the restore
   decides the binding (`ProxyBinding.routed`, PROXY-027) and residency
   reads it, routed from the first tap. `routesPerSite` is gone. A start
   that fails, its proof included, stands the router down for the run and
   takes the rule off the relay; no challenge was answered before the
   proof, so no site has loaded through a route the stand-down moves, and a
   proxied site shows the block instead of falling back to PROXY-008.
   *Why:* the user made router mode the only path on such devices, and a
   topology fixed per run is what the model already held. *Partial:* the
   one-rule path keeps every gap below on devices without per-site
   profiles; the emulator runs it only through a pinned binding
   (`integration_test/proxy_one_rule_test.dart`).

## Known open gaps

- `stopLoading` returns once Android has posted the stop; the renderer's
  cancel and the network service's teardown of each loader pipe happen
  after, and nothing the plugin or `androidx.webkit` exposes reports them.
  A request already handed to the network stack before the stop lands can
  still resolve its proxy against the next override, so the window
  attempt 18 closes is narrowed, not proved shut. A per-webview proxy
  (PROXY-013 router mode) is the case that does not depend on it.
- Not determined which load started the old site's favicon download in the
  CI run; Chromium's `IconHelper` downloads it through
  `WebContents::DownloadImage`, and whether `WebContents::Stop` cancels an
  image download already under way, rather than only frame loads, is read
  from the code's shape and not confirmed on a device.
- The quiet's `stopLoading` can meet the plugin's own dispose, which loads
  `about:blank` on the same webview. A stop beside an in-flight cross-origin
  redirect has crashed one Android WebView build before (the notes at the
  external-scheme cancel in `webview.dart` and at the nested hop in
  `web_view_model.dart`); this pair is untested on a device.

- The model holds which sites run, not the route the rule is set to: the
  order of two writes (a nested open's apply against a webview build, a
  webview build against the app's return closing a wake's checks) is
  checked by `ProcessRoute`'s assert, which the walks drive for every
  webview, the nested open and the wake; its claims and releases are
  checked on their own in `formal/process_route.tla`, not with the
  activation's flows.
- The model checks the route rule against the activation's flows only. A
  load outside the activation table (none known today) would not be seen.
- A reroute whose link was opened by a site other than its owner, or one
  that flips the tabs of several owners at once, is written outside a
  step (`Unmodeled.identityChange`); only one owner's own links are a
  step (attempt 16).
- A reroute that arrives while the tab gate is held waits in the code and
  is not taken by the model (`steps_uncovered.tsv`).
- A settings change of a site's proxy or Tor exit is checked only by the
  residency plan's unit tests: the model holds a site's route and exit as
  constants, and no walk changes a site's settings.
