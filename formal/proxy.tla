----------------------------- MODULE proxy -----------------------------
(***************************************************************************)
(* Proxy mutual exclusion (spec: proxy). Android serialises mismatched-    *)
(* proxy sites: the native layer has ONE active outbound proxy at a time   *)
(* (the visible site's), so two sites with different proxies must never be  *)
(* loaded concurrently -- activating a site unloads the proxy-mismatched    *)
(* ones, and a background load is only allowed for a proxy-compatible site. *)
(*                                                                         *)
(*   Inv_ProxyCoherent == every loaded site shares the active proxy        *)
(*                                                                         *)
(* The "mismatch" demonstrator co-loads a site with a different proxy and  *)
(* is caught. Standalone model (a fixed 3-site scenario; no shared kernel  *)
(* state), like archive.tla and renderer.tla.                              *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT Conflict   \* "none" | "mismatch"

N == 3
Sites == 1..N
\* Fixed per-site proxy assignment: sites 1 and 3 share a proxy, site 2 differs.
proxyOf == << "direct", "socks", "direct" >>

VARIABLES
    active,   \* the visible site (its proxy is the native active proxy)
    loaded    \* set of concurrently-loaded sites

vars == << active, loaded >>

TypeOK == active \in Sites /\ loaded \subseteq Sites

Init == active = 1 /\ loaded = {1}

ActiveProxy == proxyOf[active]

\* Switch to s; serialise by unloading every loaded site whose proxy differs
\* from s's (they cannot share the single native proxy slot).
Activate(s) ==
    /\ active' = s
    /\ loaded' = { t \in (loaded \cup {s}) : proxyOf[t] = proxyOf[s] }

\* Background-load a proxy-COMPATIBLE site (Android refuses to co-load a
\* mismatched-proxy site).
LoadCompatible(s) ==
    /\ s \notin loaded
    /\ proxyOf[s] = ActiveProxy
    /\ active' = active
    /\ loaded' = loaded \cup {s}

\* Unload a non-active site.
Unload(s) ==
    /\ s \in loaded
    /\ s # active
    /\ active' = active
    /\ loaded' = loaded \ {s}

\* Demonstrator: co-load a proxy-MISMATCHED site without serialising (the
\* unserialised / broken path). Violates Inv_ProxyCoherent.
LoadMismatched(s) ==
    /\ s \notin loaded
    /\ proxyOf[s] # ActiveProxy
    /\ active' = active
    /\ loaded' = loaded \cup {s}

GoodNext ==
    \/ \E s \in Sites : Activate(s)
    \/ \E s \in Sites : LoadCompatible(s)
    \/ \E s \in Sites : Unload(s)

Next == GoodNext \/ (Conflict = "mismatch" /\ \E s \in Sites : LoadMismatched(s))

Spec == Init /\ [][Next]_vars

\* SAFETY: every loaded site shares the active site's proxy. Broken by "mismatch".
Inv_ProxyCoherent == \A s \in loaded : proxyOf[s] = ActiveProxy

\* SAFETY: the active site is loaded.
Inv_ActiveLoaded == active \in loaded

\* Anti-vacuity witness (expect violated): two proxy-compatible sites can be
\* loaded together, so coherence is checked against real multi-site loading.
Reach_TwoLoaded == ~(Cardinality(loaded) >= 2)
=============================================================================
