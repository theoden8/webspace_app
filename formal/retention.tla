--------------------------- MODULE retention ---------------------------
(***************************************************************************)
(* Memory-pressure eviction cascade (PAUSE-006) + notification retention    *)
(* (web-push-notifications). Under sustained memory pressure the app evicts  *)
(* loaded sites progressively, lowest priority first:                        *)
(*                                                                          *)
(*     current  >  notification  >  normal                                  *)
(*                                                                          *)
(* The visible (current) site is NEVER evicted, and a notification site is   *)
(* evicted only once every normal non-current site is already gone (notif    *)
(* sites tier last in SiteRetentionPriority so OS pressure drops others       *)
(* first). A single pressure episode is monotone: this model only evicts.     *)
(*                                                                          *)
(* The "starve" demonstrator evicts a notification site while a normal one    *)
(* is still loaded, violating the retention guarantee; TLC catches it.        *)
(* Standalone model (a fixed scenario), like archive/renderer/proxy.          *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Conflict   \* "none" | "starve"

N == 3
Sites == 1..N
current == 1
\* Fixed tiers: site 1 is the visible site, site 2 is a normal site, site 3 is
\* a notification site (auto-loaded, retained longest).
isNotif == << FALSE, FALSE, TRUE >>

VARIABLE loaded     \* set of currently-loaded sites
vars == << loaded >>

\* A normal site: neither the visible site nor a notification site.
Normal(s) == ~isNotif[s] /\ s # current

TypeOK == loaded \subseteq Sites

\* Memory pressure starts with everything loaded and evicts from there.
Init == loaded = Sites

\* Priority-correct eviction: never the current site; a notification site only
\* when no normal non-current site remains loaded.
Evict(s) ==
    /\ s \in loaded
    /\ s # current
    /\ (isNotif[s] => \A m \in loaded : (m = current) \/ isNotif[m])
    /\ loaded' = loaded \ {s}

\* Demonstrator: evict a notification site while a normal non-current site is
\* still loaded -- the retention order violated.
EvictStarve(s) ==
    /\ s \in loaded
    /\ isNotif[s]
    /\ \E m \in loaded : Normal(m)
    /\ loaded' = loaded \ {s}

Next == (\E s \in Sites : Evict(s))
        \/ (Conflict = "starve" /\ \E s \in Sites : EvictStarve(s))

Spec == Init /\ [][Next]_vars

\* SAFETY: the visible site is never evicted under pressure.
Inv_CurrentKept == current \in loaded

\* SAFETY: notification sites are evicted last -- a notif site is unloaded only
\* once every normal non-current site is gone. Broken by "starve".
Inv_NotifLast ==
    \A n \in Sites :
        (isNotif[n] /\ n \notin loaded) =>
            (\A m \in Sites : Normal(m) => m \notin loaded)

\* Anti-vacuity witness (expect violated): a normal site actually gets evicted,
\* so the retention order is exercised, not held because nothing happens.
Reach_NormalEvicted == ~(\E s \in Sites : Normal(s) /\ s \notin loaded)
=============================================================================
