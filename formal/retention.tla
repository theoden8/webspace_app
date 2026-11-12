--------------------------- MODULE retention ---------------------------
(***************************************************************************)
(* Memory-pressure eviction cascade (PAUSE-006) + notification retention    *)
(* (web-push-notifications) + warm tabs (TAB-024). Under sustained memory   *)
(* pressure the app evicts live webviews progressively, lowest priority     *)
(* first:                                                                   *)
(*                                                                          *)
(*     current  >  notification  >  normal                                  *)
(*              >  warm on screen  >  warm hosted on screen                 *)
(*              >  warm own  >  warm hosted                                 *)
(*                                                                          *)
(* A view is a site's active webview or a warm tab's (TAB-002). The visible *)
(* (current) view is NEVER evicted, a notification site is evicted only     *)
(* once every normal non-current site is already gone, and no active view   *)
(* is evicted while a warm tab is loaded. A single pressure episode is      *)
(* monotone: this model only evicts.                                        *)
(*                                                                          *)
(* The "starve" demonstrator evicts a notification site while a normal one  *)
(* is still loaded; "activeFirst" evicts an active view while a warm tab is *)
(* loaded. TLC catches both. Standalone model (a fixed scenario), like      *)
(* archive/renderer/proxy.                                                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    N,         \* number of views (TLC sets 7; proofs use abstract N)
    current,   \* the visible view
    isNotif,   \* per-view notification flag (a function Sites -> BOOLEAN)
    warm,      \* per-view warm kind (a function Sites -> WarmKinds)
    Conflict   \* "none" | "starve" | "activeFirst"

Sites == 1..N

\* "no": a site's active webview. The others are warm tabs: listed
\* under the site on screen (own or hosted), or under another site.
WarmKinds == {"no", "onScreen", "onScreenHosted", "own", "hosted"}

ASSUME RetentionTyping ==
    /\ current \in Sites
    /\ isNotif \in [Sites -> BOOLEAN]
    /\ warm \in [Sites -> WarmKinds]
    /\ ~isNotif[current]   \* the visible site is not a notification site
    /\ warm[current] = "no"
    /\ \A s \in Sites : isNotif[s] => warm[s] = "no"

\* Concrete assignment for TLC: view 1 is visible, 2 a normal site, 3 a
\* notification site, 4 to 7 warm tabs of each kind.
IsNotifDef == << FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE >>
WarmDef == << "no", "no", "no", "onScreen", "onScreenHosted", "own", "hosted" >>

VARIABLE loaded     \* set of currently-loaded views
vars == << loaded >>

\* A normal site: neither the visible site, a notification site nor a warm tab.
Normal(s) == ~isNotif[s] /\ s # current /\ warm[s] = "no"

Warm(s) == warm[s] # "no"

\* SiteRetentionPriority read as a rank: a lower rank goes first.
Rank(s) ==
    CASE warm[s] = "hosted"          -> 1
      [] warm[s] = "own"             -> 2
      [] warm[s] = "onScreenHosted"  -> 3
      [] warm[s] = "onScreen"        -> 4
      [] isNotif[s]                  -> 6
      [] OTHER                       -> 5

TypeOK == loaded \subseteq Sites

\* Memory pressure starts with everything loaded and evicts from there.
Init == loaded = Sites

\* Priority-correct eviction: never the current view, and only a view no
\* other loaded non-current view ranks below.
Evict(s) ==
    /\ s \in loaded
    /\ s # current
    /\ \A m \in loaded : (m = current) \/ Rank(s) <= Rank(m)
    /\ loaded' = loaded \ {s}

\* Demonstrator: evict a notification site while a normal non-current site is
\* still loaded -- the retention order violated.
EvictStarve(s) ==
    /\ s \in loaded
    /\ isNotif[s]
    /\ \E m \in loaded : Normal(m)
    /\ loaded' = loaded \ {s}

\* Demonstrator: evict a non-current active view while a warm tab is still
\* loaded -- TAB-024's order violated.
EvictActiveFirst(s) ==
    /\ s \in loaded
    /\ s # current
    /\ ~Warm(s)
    /\ \E m \in loaded : Warm(m)
    /\ loaded' = loaded \ {s}

GoodNext == \E s \in Sites : Evict(s)

Next == GoodNext
        \/ (Conflict = "starve" /\ \E s \in Sites : EvictStarve(s))
        \/ (Conflict = "activeFirst" /\ \E s \in Sites : EvictActiveFirst(s))

Spec == Init /\ [][Next]_vars

\* SAFETY: the visible site is never evicted under pressure.
Inv_CurrentKept == current \in loaded

\* SAFETY: notification sites are evicted last -- a notif site is unloaded only
\* once every normal non-current site is gone. Broken by "starve".
Inv_NotifLast ==
    \A n \in Sites :
        (isNotif[n] /\ n \notin loaded) =>
            (\A m \in Sites : Normal(m) => m \notin loaded)

\* SAFETY (TAB-024): warm tabs are evicted first -- an active view is unloaded
\* only once every warm tab is gone. Broken by "activeFirst".
Inv_WarmFirst ==
    \A a \in Sites :
        (~Warm(a) /\ a \notin loaded) => (\A w \in Sites : Warm(w) => w \notin loaded)

\* Anti-vacuity witness (expect violated): a normal site actually gets evicted,
\* so the retention order is exercised, not held because nothing happens.
Reach_NormalEvicted == ~(\E s \in Sites : Normal(s) /\ s \notin loaded)
=============================================================================
