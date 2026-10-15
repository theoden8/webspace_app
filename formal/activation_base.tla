------------------------- MODULE activation_base -------------------------
(* The variables of formal/activation.tla, its constants, and the        *)
(* operators of the environment: the inputs' timing, the jar's turn      *)
(* (the SerialQueue's semantics) and the ghosts. The engines' own        *)
(* operators are printed from their definitions (activation_ops), as the *)
(* tables' steps are (activation_tables); `Outcomes` and                 *)
(* `Internal_Tables` are printed too (activation_steps). Hand-written.   *)

EXTENDS Integers, Sequences, FiniteSets, activation_steps, activation_vars

CONSTANTS
    Containers,   \* TRUE: per-site containers; FALSE: the legacy shared jar
    ColdStart,    \* TRUE: from launch, with what the last session left in
                  \* the jar; FALSE: mid-session, sites already loaded
    Mistake,      \* "none" or a planted bug of the environment's operators
                  \* (HandMistake in lib/formal_model/checks.dart); a
                  \* mistake in an engine is a printed mutant instead
    MaxInputs,    \* user and OS events in one behavior
    Tabbed,       \* sites whose tabs the model follows (TAB-003); every
                  \* site's in the code, so a config picks the few it checks
    MaxTabs,      \* tab ids a site can mint; a tab input needing one is
                  \* disabled once they are spent, as inputs are by MaxInputs
    Allowed       \* the inputs that may land: every one (Inputs), or the
                  \* few a printed world takes two actions with

N == 3
Pos == 1..N
Sites == 1..N
Flows == 1..MaxInputs
\* A site's tab ids: 1 is the tab it starts with, a tabbed site also has 2;
\* a new tab, a duplicate or the home tab after the last close takes the
\* next one (TabId.mint, which never repeats).
TabIds == 1..MaxTabs
NoQueued == [t |-> 0, h |-> 0]
\* Sites 1 and 2 share a base domain; site 3 is apart.
Base == <<1, 1, 2>>
\* Sites on a shared proxy route the activation repoints (LIR-024); the
\* page routes none.
Routed == {}
\* How the host scopes a proxy (PROXY-008): the sites in Contending share
\* one process-global rule, so a loaded one must run the Route of every
\* other; the pages bind a proxy per session, which leaves it empty.
Contending == {}
Route == <<1, 1, 1>>
\* Each site's Tor exit constraint, 0 for a site off Tor, and whether a Tor
\* runtime exists whose one ExitNodes an activation repoints; none here.
TorExit == <<0, 0, 0>>
TorRuntime == FALSE
\* How many sites may stay loaded, and how many resident before the
\* proactive cache clear: the device's (kResidencyCaps), which three sites
\* reach neither of.
MaxLoaded == 20
MaxResident == 10
\* The sites a link opens nested (LIR-011); the pages open none. A nested
\* open's proxy always applies in the model's environment.
Linked == {}
ProxyRefused == FALSE
\* Whether the platform may refuse a read, the nuke or a write of the shared
\* jar (ISO-014); the pages' jar never does.
JarRefuses == FALSE
\* The sites with notifications on, which a background wake checks
\* (NOTIF-016), and whether the app goes to the background at all; the
\* pages have none and stay on screen.
Notified == {}
Waking == FALSE
\* The DNS level each site asks for, -1 to follow the app-wide one, 0 for
\* off (WebViewModel.dnsBlockLevel), and the levels a download may pick
\* (DNS-019, DNS-021); the pages download none, which leaves the views
\* unbuilt and the DNS inputs off.
SiteLevel == [s \in Sites |-> -1]
DnsLevels == {}
\* What a webspace switch may stop showing (WEBSPACE-013), any of these,
\* and whether the device answers its check online; the pages switch
\* none.
Away == {}
Online == TRUE
\* The sites of the one open archive, which a close takes off the list
\* (ARCH-007, ARCH-014); the pages have none. Containers only: the archive
\* is not offered on the shared jar.
Archive == {}
\* The sites a delete may name (SiteDeletion); the pages delete none.
Deletable == {}
\* The sites whose webviews and containers the model follows: what a close
\* or a delete takes away.
Boxed == Archive \cup Deletable
\* Incognito sites keep nothing to capture or restore, and a tab in
\* NoNavState keeps no back stack (a kiosk's); an archive's sites are both
\* (ARCH-006), and an incognito site keeps no back stack either
\* (WebViewModel.persistsNavState).
Incognito == Archive
NoNavState == Incognito
\* The sites on the list, the only ones an input can name.
Listed == Sites \ gone

\* The variables are activation_vars, printed from ModelVar, grouped here.
site == << rows, loaded, current, version, marker, tier, nested, headless, fore >>
sessions == << jar, stored, signedIn >>
turn == << holder, queue >>
ghosts == << newest, evictedShown, seen >>
tabVars == << tabs, active, built, hist, queued, file, minted >>
blocking == << dns, told >>
archived == << gone, views, boxes >>
vars == << site, sessions, turn, fl, inputs, ghosts, last, tabVars, blocking,
           archived >>

\* What two states must agree on to be one: everything but `last`.
View == << site, sessions, turn, fl, inputs, ghosts, tabVars, blocking,
           archived >>

\* A nested screen covers the page: until it pops, no input the user makes
\* on the page lands, only a launch preload and the OS's memory pressure.
\* Off screen the user makes none either: what lands is the OS's (a
\* preload, memory pressure, a wake) and the app's return. What an input
\* needs of the constants (the app going to the background, a DNS level to
\* clear) is its table's guard.
NotUser == {"Preload", "Pressure", "Wake", "Background", "Foreground"}
Lands(a) ==
    /\ a \in Allowed
    /\ nested = 0 \/ a \in {"Preload", "Pressure"}
    /\ fore \/ a \in NotUser

\* Every action records itself; an input lands only where it may, so each
\* is its own action in TLC's coverage.
Did(a, f, o, s) ==
    /\ last' = [a |-> a, f |-> f, o |-> o, s |-> s]
    /\ a \in Inputs => Lands(a)

NoMarker == [t |-> 0, v |-> 0]


\* Steps that run between two awaits run before any event lands. A flow the
\* jar's turn is handed to takes it as any other step: the queue hands it on
\* in a microtask, unordered with the continuation of the flow that passed it
\* and with whatever else is due.
Internal == Internal_Tables
Queued == {"uTurn", "rTurn"}
Granted(f) ==
    /\ fl[f].pc \in Queued
    /\ \/ Mistake = "noturns"
       \/ holder = 0 /\ queue # << >> /\ Head(queue) = f
Calm == \A f \in Flows : fl[f].pc \notin Internal
Idle == \A f \in Flows : fl[f].pc = "done"

\* The next tab id a site takes (TabId.mint, which never repeats), while
\* the pool lasts; a tab input that needs one waits for none.
HasFresh(s) == minted[s] < MaxTabs
Mint(s) == minted[s] + 1

\* A flow starts on the next number while the inputs last: an input's, or
\* one a step starts in its own turn (Spawn), which counts as an input.
Starts == inputs < MaxInputs /\ inputs' = inputs + 1

\* An input lands only when every flow waits on a reply, as an event does in
\* Dart, and starts the flow numbered by its place among the inputs.
Input == Calm /\ Starts

\* The kinds of the flows in flight, which the inputs' guards read: a
\* pressure event lands on no pressure plan, a preload on no preload.
Kinds == {fl[g].kind : g \in Flows}

Enqueue(f) ==
    IF Mistake = "noturns"
    THEN UNCHANGED << queue, seen >>
    ELSE /\ queue' = Append(queue, f)
         /\ seen' = seen \cup (IF holder # 0 THEN {"queued"} ELSE {})
Release == IF Mistake \in {"noturns", "keepturn"} THEN UNCHANGED holder ELSE holder' = 0

TypeOK ==
    /\ rows \in [Pos -> Sites]
    /\ loaded \subseteq Sites
    /\ current \in Sites \cup {0}
    /\ nested \in Sites \cup {0}
    /\ headless \subseteq Sites
    /\ fore \in BOOLEAN
    /\ marker.t \in Sites \cup {0}
    /\ tier \in [Sites -> {"resident", "cleared", "saved"}]
    /\ jar \subseteq Sites
    /\ stored \in [Sites -> SUBSET Sites]
    /\ holder \in Flows \cup {0}
    /\ last.a = "init" \/ last.o \in Outcomes[last.a]
    /\ tabs \in [Sites -> SUBSET TabIds]
    /\ active \in [Sites -> TabIds]
    /\ built \in [Sites -> TabIds \cup {0}]
    /\ hist \in [Sites -> TabIds \cup {0}]
    /\ queued \in [Sites -> [t : TabIds \cup {0}, h : TabIds \cup {0}]]
    /\ file \in [Sites -> [TabIds -> TabIds \cup {0}]]
    /\ minted \in [Sites -> TabIds]
    /\ dns.lvl \in 0..5
    /\ dns.levels \subseteq 1..5
    /\ told \in [Sites -> -1..5]
    /\ gone \subseteq Sites
    /\ views \subseteq Sites
    /\ boxes \subseteq Sites

-----------------------------------------------------------------------------
\* The live activation: the newest, not superseded since it began. A ghost,
\* so the marker is held to it (the markerbytarget mutant).
LiveTarget == IF newest # 0 /\ fl[newest].v = version THEN fl[newest].site ELSE 0

\* The jar's turn starts: an unload of a site no longer loaded returns at
\* once; a superseded restore bails.
TakeTurn(f) ==
    IF Mistake = "noturns" THEN UNCHANGED << holder, queue >>
    ELSE /\ holder' = f
         /\ queue' = Tail(queue)
PassTurn ==
    IF Mistake = "noturns" THEN UNCHANGED << holder, queue >>
    ELSE /\ holder' = 0
         /\ queue' = Tail(queue)

=============================================================================
