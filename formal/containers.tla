--------------------------- MODULE containers ---------------------------
(***************************************************************************)
(* Per-site container keyspace disjointness (spec: per-site-containers).    *)
(* Each site binds to its own native container `ws-<siteId>` owning its      *)
(* cookies, localStorage, IDB, ServiceWorkers and HTTP cache. The isolation  *)
(* guarantee is RELATIONAL: distinct sites never resolve to the same         *)
(* container, so one site can never read another's storage.                  *)
(*                                                                          *)
(*   Inv_Disjoint == the site → container binding is injective              *)
(*                                                                          *)
(* The "alias" demonstrator binds a new site to an already-used container    *)
(* (the per-site isolation broken — two sites share a keyspace); TLC catches *)
(* it. Standalone model (a fixed scenario), like archive/renderer/proxy.     *)
(*                                                                          *)
(* Hosted tabs (LIR-018) let a site's slot bind another site's container.   *)
(* The slot then has to apply that site's posture too, cookie mirror        *)
(* included, or the owner's mirror and settings describe a keyspace they    *)
(* do not own:                                                              *)
(*                                                                          *)
(*   Inv_PostureMatchesContainer == every slot binds the container of the   *)
(*                                  site whose posture it applies           *)
(*                                                                          *)
(* The "ownermirror" demonstrator rebinds a slot to the host's container    *)
(* while it keeps mirroring cookies to the owner.                           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,         \* bounded number of sites (TLC sets N = 3; proofs use abstract N)
    Conflict   \* "none" | "alias" | "ownermirror"

Sites == 1..N

VARIABLES
    created,   \* sites that have been created so far
    cont,      \* cont[s] = container id bound to site s (its dedicated id is s; 0 = none)
    bound,     \* bound[s] = container site s's webview slot binds (0 = none)
    posture    \* posture[s] = site whose posture and cookie mirror slot s applies

vars == << created, cont, bound, posture >>

TypeOK ==
    /\ created \subseteq Sites
    /\ cont \in [Sites -> (Sites \cup {0})]
    /\ bound \in [Sites -> (Sites \cup {0})]
    /\ posture \in [Sites -> (Sites \cup {0})]

Init ==
    /\ created = {}
    /\ cont = [s \in Sites |-> 0]
    /\ bound = [s \in Sites |-> 0]
    /\ posture = [s \in Sites |-> 0]

\* Create a site bound to its OWN dedicated container (id = its index). Its
\* slot runs as itself.
Create(s) ==
    /\ s \notin created
    /\ created' = created \cup {s}
    /\ cont' = [cont EXCEPT ![s] = s]
    /\ bound' = [bound EXCEPT ![s] = s]
    /\ posture' = [posture EXCEPT ![s] = s]

\* LIR-018: slot s switches to a tab that runs as i (i = s is back to the
\* owner). The rebuilt webview binds i's container and applies i's posture.
Rebind(s, i) ==
    /\ s \in created
    /\ i \in created
    /\ bound' = [bound EXCEPT ![s] = cont[i]]
    /\ posture' = [posture EXCEPT ![s] = i]
    /\ UNCHANGED << created, cont >>

\* Demonstrator: create a site but bind it to an ALREADY-USED container
\* (aliasing — two sites share storage; per-site isolation broken).
CreateAliased(s) ==
    /\ s \notin created
    /\ \E t \in created :
        /\ created' = created \cup {s}
        /\ cont' = [cont EXCEPT ![s] = cont[t]]
        /\ bound' = [bound EXCEPT ![s] = cont[t]]
        /\ posture' = [posture EXCEPT ![s] = s]

\* Demonstrator: slot s binds i's container but keeps its owner's posture,
\* so the owner's cookie mirror records the host's cookies.
RebindOwnerMirror(s, i) ==
    /\ s \in created
    /\ i \in created
    /\ bound' = [bound EXCEPT ![s] = cont[i]]
    /\ UNCHANGED << created, cont, posture >>

GoodNext == \/ \E s \in Sites : Create(s)
            \/ \E s, i \in Sites : Rebind(s, i)

Next == GoodNext
        \/ (Conflict = "alias" /\ \E s \in Sites : CreateAliased(s))
        \/ (Conflict = "ownermirror" /\ \E s, i \in Sites : RebindOwnerMirror(s, i))

Spec == Init /\ [][Next]_vars

\* SAFETY: the site → container binding is injective over created sites, so no
\* two sites share a container keyspace. Broken by "alias".
Inv_Disjoint == \A i, j \in created : (i # j) => (cont[i] # cont[j])

\* SAFETY (LIR-018): each slot binds the container of the site whose posture
\* and cookie mirror it applies. Broken by "ownermirror".
Inv_PostureMatchesContainer ==
    \A s \in created : posture[s] \in created /\ bound[s] = cont[posture[s]]

\* Anti-vacuity witness (expect violated): a slot runs as another site.
Reach_Hosted == ~(\E s \in created : posture[s] # s)

\* Anti-vacuity witness (expect violated): at least two sites get created, so the
\* disjointness invariant is exercised against real multi-site binding.
Reach_TwoCreated == ~(Cardinality(created) >= 2)
=============================================================================
