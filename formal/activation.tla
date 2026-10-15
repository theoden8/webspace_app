----------------------------- MODULE activation -----------------------------
(***************************************************************************)
(* Site activation at the granularity of its awaits. Three sites on two     *)
(* base domains; taps, home, memory pressure, row moves and sign-ins land   *)
(* only when every flow waits on a platform reply, as an event does in      *)
(* Dart; between replies a flow runs to its next await. What runs between   *)
(* two awaits is one step, and those steps are the code's own:              *)
(*                                                                          *)
(*   activate           SiteActivationController: version bump and marker,  *)
(*                      nav-state load, residency plan, each conflict       *)
(*                      unload, the pause of the site it leaves, the jar    *)
(*                      restore or the container, commit, the target's      *)
(*                      resume, and the finally (marker, home if the shown  *)
(*                      site is gone)                                       *)
(*   memoryPressure     one event clears a resident site's cache or         *)
(*                      unloads a cleared one, picked by retention priority *)
(*   SiteUnloadEngine   the plan's unloads, then its cache clears: a nav    *)
(*                      capture, then on the shared jar the capture in the  *)
(*                      jar's turn, then dispose, which makes the site      *)
(*                      "saved"; printed from the engine's step table       *)
(*   CookieIsolation    one operation on the jar at a time (SerialQueue):   *)
(*                      restore = snapshot, save each loaded share, nuke,   *)
(*                      load the target's, refill it, refill each other's;  *)
(*                      printed from the engine's step tables               *)
(*                      (activation_tables, with the unload's)              *)
(*   SitesMoved         rows move and the version is bumped; loaded and     *)
(*                      current name sites, so the move leaves them as they *)
(*                      are, and no flow holds a row across an await        *)
(*   preload            SiteActivationController.preload, a notification    *)
(*                      site loaded off screen at launch: an activation     *)
(*                      that does not show, with no other in flight, its    *)
(*                      nav-state load, then the jar restore or the         *)
(*                      container, and a commit that leaves the screen      *)
(*   clearUnloaded      the jar emptied in its turn while no site is        *)
(*                      loaded, queued at launch before any input (ColdStart)*)
(*   DnsBlockService    a DNS list downloaded as the app-wide level or as   *)
(*                      one a site asks for, or every list cleared: its     *)
(*                      fetch, then the lists and the level in force and    *)
(*                      each live view told its site's level, as one write; *)
(*                      a frame builds and drops the views (DNS-022)        *)
(*                                                                          *)
(* Invariants, at rest where the code only promises them at rest:           *)
(*   Inv_ShownLoaded       the site on screen is loaded (LAZY-007)          *)
(*   Inv_OneSitePerBase    the shared jar never holds two loaded sites of   *)
(*                         one base domain (ISO-001)                        *)
(*   Inv_NoSessionLoss     a signed-in site's session is in the jar while   *)
(*                         loaded, in its storage otherwise (BUG-032)       *)
(*   Inv_NoForeignSession  no site's storage or jar share holds another's   *)
(*   Inv_NoShownEvicted    no unload disposes the live activation's target, *)
(*                         and none picked by priority the site on screen   *)
(*                         (PAUSE-006, BUG-033)                             *)
(*   Inv_LoadedNotSaved    no loaded site sits at "saved", where pressure   *)
(*                         never picks it (BUG-033)                         *)
(*   Inv_Places            what each of the jar's places needs, printed     *)
(*                         from Step.holds: the jar's turn (ISO-003)        *)
(*   Inv_Told              every live view runs the level its site resolves *)
(*                         to under the lists in force (DNS-022)            *)
(*                                                                          *)
(* Mistake plants one bug the environment's operators once had; each must  *)
(* break an invariant or end in a deadlock. A mistake in a step table or an *)
(* engine's definition is a mutant instead: a copy with the fault, printed  *)
(* beside the real one. The worlds this is checked in, the witnesses it    *)
(* must reach and both kinds of mistake are the enums of                    *)
(* lib/formal_model/checks.dart, each printed as one TLC config.            *)
(*                                                                          *)
(* The cold start's clear is housekeeping, not what keeps sessions apart:  *)
(* every load restores, and a restore saves only loaded sites' shares and  *)
(* nukes before it refills, so what the last session left never reaches a  *)
(* site; the clear only keeps it from outliving a launch that opens none.  *)
(*                                                                          *)
(* Each action is one step the code marks (ActivationStep in                *)
(* lib/services/activation_step.dart, the same names and outcomes), and     *)
(* records itself in `last`: its name, its flow, the branch it took and the *)
(* site it chose. formal/trace/check_steps.sh replays every schedule        *)
(* test/activation_schedules_test.dart runs, mark by mark, as a behavior of *)
(* this spec. Standalone: kernel.tla abstracts activation as one step and   *)
(* keeps its TLAPS proofs.                                                  *)
(*                                                                          *)
(* Modules: activation_base (variables, constants and the environment's    *)
(* operators, hand-written); activation_steps (Outcomes, from              *)
(* ActivationStep), activation_ops (the engines' operators, from their     *)
(* definitions) and activation_tables (every step, from the tables of      *)
(* SiteActivationController, SiteUnloadEngine and CookieIsolationEngine),  *)
(* all printed by formal/verify.sh and never committed; this file, the     *)
(* environment's inputs, the invariants, the mistakes and the witnesses.   *)
EXTENDS activation_tables

-----------------------------------------------------------------------------
(* Init, mid-session: one site signed in on screen, or a second on the other *)
(* base domain loaded in the background, as the Dart schedules' setups. At  *)
(* launch (ColdStart): no site loaded, each signed-in site's session in its *)
(* storage, the jar holding whatever the last session left, any site's,     *)
(* and its clear queued for the jar's first turn.                           *)

WarmInit ==
    /\ current = 1
    /\ \/ /\ loaded = {1}
          /\ signedIn = IF Containers THEN {} ELSE {1}
          /\ stored = [s \in Sites |-> {}]
       \/ /\ loaded = {1, 3}
          /\ signedIn = IF Containers THEN {} ELSE {1, 3}
          /\ stored = [s \in Sites |-> IF s = 3 /\ ~Containers THEN {3} ELSE {}]
    \* The sites a session left loaded could run together: on one route and
    \* one Tor exit where a world splits them (PROXY-008, TOR-025).
    /\ \A s, t \in loaded :
        /\ s \in Contending /\ t \in Contending => Route[s] = Route[t]
        /\ TorRuntime /\ TorExit[s] # 0 /\ TorExit[t] # 0 =>
               TorExit[s] = TorExit[t]
    /\ jar = signedIn
    /\ queue = << >>

ColdInit ==
    /\ current = 0
    /\ loaded = {}
    \* An incognito site keeps no session across a restart (INC-001).
    /\ signedIn \in IF Containers THEN {{}} ELSE SUBSET (Sites \ Incognito)
    /\ stored = [s \in Sites |-> IF s \in signedIn THEN {s} ELSE {}]
    /\ jar \in IF Containers THEN {{}} ELSE SUBSET Sites
    /\ queue = IF Containers \/ Mistake = "lateclear" THEN << >> ELSE << 0 >>

Init ==
    /\ rows = [q \in Pos |-> q]
    /\ IF ColdStart THEN ColdInit ELSE WarmInit
    /\ version = 0
    /\ marker = NoMarker
    /\ nested = 0
    /\ headless = {}
    /\ fore = TRUE
    /\ tier = [s \in Sites |-> "resident"]
    /\ holder = 0
    /\ fl = [f \in Flows |-> NoFlow]
    /\ inputs = 0
    /\ newest = 0
    /\ evictedShown = FALSE
    /\ seen = {}
    /\ last = [a |-> "init", f |-> 0, o |-> "", s |-> 0]
    /\ tabs = [s \in Sites |-> IF s \in Tabbed THEN {1, 2} ELSE {1}]
    /\ active = [s \in Sites |-> 1]
    /\ built = [s \in Sites |-> IF s \in Tabbed /\ s \in loaded THEN 1 ELSE 0]
    /\ hist = built
    /\ queued = [s \in Sites |-> NoQueued]
    /\ file = [s \in Sites |-> [t \in TabIds |-> 0]]
    /\ minted = [s \in Sites |-> IF s \in Tabbed THEN 2 ELSE 1]
    /\ dns = [lvl |-> 0, levels |-> {}]
    /\ told = [s \in Sites |-> -1]
    /\ gone = {}
    \* Where an archive is open, a loaded site's webview is mounted and an
    \* archive site's container is on disk once it was.
    /\ views = IF Boxed = {} THEN {} ELSE loaded
    /\ boxes = Boxed \cap loaded

-----------------------------------------------------------------------------
(* Inputs. The tables start the flows (InputTableStep, printed); the rest *)
(* is the environment: a row move the user makes, a page signing in, and  *)
(* the launch clear, flow 0.                                               *)

\* SitesMoved(from, to): models.insert(to, models.removeAt(from)).
Moved(i, from, to) ==
    CASE i = 0 -> 0
      [] i = from -> to
      [] from < to /\ from < i /\ i <= to -> i - 1
      [] to < from /\ to <= i /\ i < from -> i + 1
      [] OTHER -> i

\* What the runtime and every flow hold names sites, so a move changes
\* nothing else and supersedes no flow in flight (BUG-029).
Move(from, to) ==
    /\ Input
    /\ from # to
    \* The model keeps every row; once a close took some off the list it
    \* moves none (the archive configs).
    /\ gone = {}
    /\ rows' = [q \in Pos |-> rows[CHOOSE j \in Pos : Moved(j, from, to) = q]]
    /\ seen' = seen \cup (IF Idle THEN {} ELSE {"movedMidFlight"})
    /\ Did("Move", inputs + 1, "", 0)
    /\ UNCHANGED << loaded, current, version, marker, tier, nested, headless, fore,
                    sessions, turn, fl, newest, evictedShown, tabVars,
                    blocking, archived >>

\* A loaded site's page signs in. Only at rest: a page write inside another
\* site's capture-nuke-restore is lost by design of the shared jar.
Login(s) ==
    /\ Input
    /\ ~Containers
    /\ Idle
    /\ s \in loaded
    /\ jar' = jar \cup {s}
    /\ signedIn' = signedIn \cup {s}
    /\ Did("Login", inputs + 1, "", s)
    /\ UNCHANGED << site, stored, turn, fl, ghosts, tabVars, blocking,
                    archived >>

\* clearUnloaded at launch: the jar's first turn, emptied while nothing is
\* loaded. "lateclear" runs it once whenever, outside the turns.
ClearJar ==
    /\ Calm
    /\ ~Containers
    /\ IF Mistake = "lateclear"
       THEN /\ ColdStart /\ "lateclear" \notin seen
            /\ seen' = seen \cup {"lateclear"}
            /\ UNCHANGED queue
       ELSE /\ holder = 0 /\ queue # << >> /\ Head(queue) = 0
            /\ queue' = Tail(queue)
            /\ UNCHANGED seen
    /\ jar' = {}
    /\ Did("ClearJar", 0, "", 0)
    /\ UNCHANGED << site, stored, signedIn, holder, fl, inputs, newest,
                    evictedShown, tabVars, blocking, archived >>

\* The level a site's webview runs at with the lists in force now
\* (DnsBlockService.effectiveLevelFor).
Eff(s) == ResolveLevel(SiteLevel[s], dns.lvl, dns.levels)

\* A frame builds a loaded site's webview, which attaches its native
\* interceptor at the level its site resolves to now; a frame drops one
\* whose site has gone (ViewBlockers.built, gone). Only where DNS is in
\* play: the other configs build no view.
ViewBuilt(s) ==
    /\ Calm
    /\ DnsLevels # {}
    /\ s \in loaded
    /\ told[s] = -1
    /\ told' = [told EXCEPT ![s] = Eff(s)]
    /\ Did("ViewBuilt", 0, "", s)
    /\ UNCHANGED << site, sessions, turn, fl, inputs, ghosts, tabVars, dns,
                    archived >>

ViewGone(s) ==
    /\ Calm
    /\ s \notin loaded
    /\ told[s] # -1
    /\ told' = [told EXCEPT ![s] = -1]
    /\ Did("ViewGone", 0, "", s)
    /\ UNCHANGED << site, sessions, turn, fl, inputs, ghosts, tabVars, dns,
                    archived >>

\* A frame mounts a loaded site's webview, which binds its container, and
\* unmounts one whose site is no longer loaded (SiteWebviewStack). Only
\* where a close or a delete can take a site away: the other configs follow
\* no view's mount.
Frame(s) ==
    /\ Calm
    /\ Boxed # {}
    /\ (s \in loaded) # (s \in views)
    /\ IF s \in loaded
       THEN /\ views' = views \cup {s}
            /\ boxes' = IF s \in Boxed THEN boxes \cup {s} ELSE boxes
       ELSE /\ views' = views \ {s}
            /\ UNCHANGED boxes
    /\ Did("Frame", 0, "", s)
    /\ UNCHANGED << site, sessions, turn, fl, inputs, ghosts, tabVars,
                    blocking, gone >>

-----------------------------------------------------------------------------

\* Every flow finished and the launch clear run: a behavior may end there,
\* whether or not it spent its inputs (a printed world allows few). It may
\* end too where a step would start a flow once the inputs are spent
\* (Spawning_Tables): the bound cuts the code off there, as it cuts off an
\* input.
Done ==
    /\ \/ Idle /\ queue = << >>
       \/ inputs = MaxInputs /\ \E f \in Flows : fl[f].pc \in Spawning_Tables
    /\ UNCHANGED vars

\* Every step one flow can take.
FlowStep(f) == TableStep(f)

\* Where a table's input may land is Lands, in activation_base.
InputStep ==
    \/ \E f \in Flows : InputTableStep(f)
    \/ nested = 0 /\ fore /\ \E from, to \in Pos : Move(from, to)
    \/ \E s \in Sites : Login(s)

Next ==
    \/ InputStep
    \/ \E f \in Flows : FlowStep(f)
    \/ \E s \in Sites : ViewBuilt(s) \/ ViewGone(s)
    \/ \E s \in Sites : Frame(s)
    \/ ClearJar
    \/ Done

Spec == Init /\ [][Next]_vars

\* What proofs/activation_turns.tla proves inductive; the tables' steps are
\* its cases printed from them (activation_tables_proof). Good: the jar's
\* turns are real, which the noturns mistake drops.
Good == Mistake # "noturns"

FlowsOK ==
    /\ DOMAIN fl = Flows
    /\ \A g \in Flows : DOMAIN fl[g] = DOMAIN NoFlow

\* A flow no input has started yet is idle, so an input that starts it
\* overwrites no flow in the middle of a step.
Fresh == \A g \in Flows : g > inputs => fl[g].pc = "done"

IndInv == inputs \in Nat /\ FlowsOK /\ Fresh /\ Inv_Places

-----------------------------------------------------------------------------

Inv_ShownLoaded == Idle /\ current # 0 => current \in loaded

Inv_OneSitePerBase ==
    ~Containers =>
        \A s, t \in loaded : s # t => Base[s] # Base[t]

\* A deleted site's session goes with it, and an incognito site keeps none
\* once its webview goes (INC-001); while loaded, its session is the jar's.
Inv_NoSessionLoss ==
    (~Containers /\ Idle) =>
        \A s \in signedIn \ gone :
            IF s \in loaded THEN s \in jar ELSE s \in Incognito \/ s \in stored[s]

Inv_NoForeignSession ==
    ~Containers =>
        /\ \A s \in Sites : stored[s] \subseteq {s}
        /\ Idle => \A s \in loaded : Share(s, jar) \subseteq {s}

Inv_NoShownEvicted == ~evictedShown

\* While a webspace switch stands, no site it stopped showing is on screen:
\* a tap begun on the list before it does not open one (WEBSPACE-013).
Inv_LeftHidden ==
    \A f \in Flows :
        (fl[f].kind = "space" /\ fl[f].v = version) => current \notin fl[f].away

\* pickPromotionTarget never picks a loaded site at "saved", so one left
\* there is out of memory pressure's reach.
Inv_LoadedNotSaved == Idle => \A s \in loaded : tier[s] # "saved"

\* TAB-003: a site's webview shows the history of the tab it was built for
\* (bytes queued for another tab are dropped), each tab's file holds its
\* own history (a capture keys by the webview's tab), the webview is the
\* active tab's whenever one is built (list, pointer and webview move in
\* one turn), and at rest a loaded site shows its active tab.
Inv_TabShown == \A s \in Tabbed : built[s] # 0 => hist[s] = built[s]
\* PROXY-008: running sites in one proxy scope run one route, and running
\* Tor sites one exit, so no site's traffic leaves through another's proxy:
\* the loaded ones, the one a nested screen runs as and the ones a wake
\* checks headless.
\* Stated from the rules, not from RouteFree, which the preload's guard
\* reads: a mistake in the guard is one this catches.
Inv_OneRoute ==
    \A s \in Running :
        /\ ProxyContenders(s) = {}
        /\ TorRuntime => TorDissenters(s) = {}

\* NOTIF-016: the app back on screen ends every check a wake runs, so the
\* site the user opens next never moves the rule under one still loading.
Inv_ChecksOffScreen == fore => headless = {}

\* Every live webview's interceptor runs the level its site resolves to
\* under the lists in force, whatever landed since it was built (DNS-022):
\* a fold tells each view as the partition and the app-wide level move
\* together.
Inv_Told == \A s \in Sites : told[s] \in {-1, Eff(s)}

\* The proxy configs' environment: every site in the one process-global
\* scope, sites 1 and 2 on one route and site 3 on another.
ProxyGlobal == Sites
RouteSplit == <<1, 1, 2>>
\* The router's: sites 1 and 3 share its default session, and an
\* activation of either repoints that shared route first (LIR-024).
RouterShared == {1, 3}
\* The Tor config's: sites 1 and 2 on Tor with different exits, site 3
\* off Tor, a runtime present (TOR-025).
ExitSplit == <<1, 2, 0>>
TorOn == TRUE
\* The nested configs': a link may open any site nested (LIR-011).
LinkAny == Sites
\* The wake configs': every site's notifications on, and the app goes
\* to the background (NOTIF-016).
NotifyAll == Sites
WakesUp == TRUE
\* Site 1 follows the app-wide level, site 2 asks for level 2, site 3 has
\* DNS blocking off; downloads pick level 1 or 2.
DnsAsk == <<-1, 2, 0>>
DnsTwo == {1, 2}
\* The cap config's: two sites loaded, one of them resident.
CapTwo == 2
ResidentOne == 1
\* The webspace configs': `All`, sites 1 and 2, and site 3; a switch
\* between two of them stops showing one of these (WEBSPACE-013).
AwaySpaces == {{}, {3}, {1, 2}}

\* ARCH-007, ARCH-014: once a close or a delete has taken sites off the
\* list, at rest none is loaded or on screen, none has a webview mounted,
\* and none's container is on disk.
Inv_Retired ==
    Idle => gone \cap (loaded \cup views \cup boxes \cup {current}) = {}

\* The archive configs': site 3, on its own base domain.
ArchiveOne == {3}
\* The delete config's: site 1, on screen at the start.
DeleteOne == {1}
\* The incognito config's: site 3, loaded and signed in at the start.
IncognitoOne == {3}

Inv_TabFiles == \A s \in Tabbed : \A t \in TabIds : file[s][t] \in {0, t}
Inv_TabBound == \A s \in Tabbed : built[s] \in {0, active[s]}
Inv_TabActive == Idle => \A s \in Tabbed :
    /\ active[s] \in tabs[s]
    /\ (s \in loaded => built[s] = active[s])

\* Witnesses (expect violated): the interleavings the invariants constrain
\* are reachable.
Reach_BailAfterUnload == "bailAfterUnload" \notin seen
Reach_TurnQueued == "queued" \notin seen
Reach_BackOff == "backoff" \notin seen
Reach_EvictMidActivation == "evictMidActivation" \notin seen
Reach_MovedMidFlight == "movedMidFlight" \notin seen
Reach_Preloaded == "preloaded" \notin seen
\* A tap's plan picks by the loaded-site cap: the cap config is not vacuous.
Reach_CapPicked ==
    ~\E f \in Flows : fl[f].kind = "tap" /\ fl[f].pc = "next" /\ fl[f].picked # {}
\* A tap whose plan names a proxy contender reaches its unloads: the
\* proxy configs are not vacuous.
\* A nested screen is up beside a loaded site, and a nested open unloads
\* the sites its screen would repoint: the nested configs are not vacuous.
Reach_NestedBeside == ~(nested # 0 /\ loaded # {})
Reach_NestedUnloads ==
    ~\E f \in Flows : fl[f].kind = "nested" /\ fl[f].pc = "next"
\* A webspace switch reaches the unloads of what it left behind: the
\* webspace configs are not vacuous.
Reach_SpaceUnloads ==
    ~\E f \in Flows : fl[f].kind = "space" /\ fl[f].pc = "next"
\* A wake checks a site headless beside a loaded one, and passes over one
\* that may not run beside what runs: the wake configs are not vacuous.
Reach_WakeBeside == ~(headless # {} /\ loaded # {})
Reach_DnsTells == "dnsTells" \notin seen
\* A close takes its sites off the list while a tap is in flight, which it
\* supersedes: the archive config is not vacuous.
Reach_CloseSupersedes ==
    ~(last.a = "CloseDropReply" /\ \E f \in Flows : fl[f].kind = "tap" /\ fl[f].pc # "done")
\* A delete takes the site on screen off the list while a tap is in flight:
\* the delete config is not vacuous.
Reach_DeleteSupersedes ==
    ~(last.a = "DeleteDropReply" /\ \E f \in Flows : fl[f].kind = "tap" /\ fl[f].pc # "done")
\* A restore sets a loaded incognito site's session back once the jar is
\* emptied: the incognito config is not vacuous (INC-001).
Reach_IncognitoKept ==
    ~(last.a = "RestoreSetOtherReply" /\ last.s \in Incognito)
Reach_WakeSkips == ~(last.a = "WakeAsk" /\ last.o = "skip" /\ fore = FALSE)
\* A rebind that reroutes the slot starts the activation that opens it again
\* in the same turn, on the flow numbered last: the routed tabs config is not
\* vacuous (LIR-024).
Reach_Reopened ==
    ~(/\ last.a = "TabRebind" /\ last.o = "unload"
      /\ \E g \in Flows : g = inputs /\ fl[g].kind = "tap" /\ fl[g].site = last.s
                          /\ fl[g].v = version)
Reach_RouteSwitch ==
    ~\E f \in Flows : fl[f].kind = "tap" /\ fl[f].pc = "next"
                       /\ ProxyContenders(fl[f].site) # {}
\* A tap whose plan names a Tor site on another exit reaches its unloads:
\* the Tor config is not vacuous.
Reach_ExitSwitch ==
    ~\E f \in Flows : fl[f].kind = "tap" /\ fl[f].pc = "next"
                       /\ TorDissenters(fl[f].site) # {}
=============================================================================
