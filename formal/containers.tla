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
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,         \* bounded number of sites (TLC sets N = 3; proofs use abstract N)
    Conflict   \* "none" | "alias"

Sites == 1..N

VARIABLES
    created,   \* sites that have been created so far
    cont       \* cont[s] = container id bound to site s (its dedicated id is s; 0 = none)

vars == << created, cont >>

TypeOK ==
    /\ created \subseteq Sites
    /\ cont \in [Sites -> (Sites \cup {0})]

Init ==
    /\ created = {}
    /\ cont = [s \in Sites |-> 0]

\* Create a site bound to its OWN dedicated container (id = its index).
Create(s) ==
    /\ s \notin created
    /\ created' = created \cup {s}
    /\ cont' = [cont EXCEPT ![s] = s]

\* Demonstrator: create a site but bind it to an ALREADY-USED container
\* (aliasing — two sites share storage; per-site isolation broken).
CreateAliased(s) ==
    /\ s \notin created
    /\ \E t \in created :
        /\ created' = created \cup {s}
        /\ cont' = [cont EXCEPT ![s] = cont[t]]

GoodNext == \E s \in Sites : Create(s)

Next == GoodNext
        \/ (Conflict = "alias" /\ \E s \in Sites : CreateAliased(s))

Spec == Init /\ [][Next]_vars

\* SAFETY: the site → container binding is injective over created sites, so no
\* two sites share a container keyspace. Broken by "alias".
Inv_Disjoint == \A i, j \in created : (i # j) => (cont[i] # cont[j])

\* Anti-vacuity witness (expect violated): at least two sites get created, so the
\* disjointness invariant is exercised against real multi-site binding.
Reach_TwoCreated == ~(Cardinality(created) >= 2)
=============================================================================
