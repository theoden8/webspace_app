----------------------------- MODULE proxy -----------------------------
(***************************************************************************)
(* Per-site proxy routing (spec: proxy). Two Android designs, one safety  *)
(* property.                                                              *)
(*                                                                        *)
(*   Router = "off" -- PROXY-008. The native layer has ONE outbound proxy *)
(*     at a time (the visible site's), so mismatched sites are serialised: *)
(*     activating a site unloads the proxy-mismatched ones, and a          *)
(*     background load is only allowed for a proxy-compatible site.        *)
(*                                                                        *)
(*   Router = "on"  -- PROXY-013. The one native rule points at a loopback *)
(*     router for good, and each site reaches its own upstream through its *)
(*     own credential. Mismatched sites co-load freely.                    *)
(*                                                                        *)
(* The property the user actually cares about is the same either way, so   *)
(* it is what the model asserts:                                           *)
(*                                                                        *)
(*   Inv_EgressMatchesConfig == every loaded site egresses through the     *)
(*                             proxy IT was configured with               *)
(*                                                                        *)
(* Inv_ProxyCoherent (every loaded site shares the active proxy) is the    *)
(* mechanism PROXY-008 uses to get there, not the goal; under router mode  *)
(* it is false by design, so it is asserted only in the "off" configs.     *)
(*                                                                        *)
(* Two demonstrators, one per design:                                      *)
(*                                                                        *)
(*   Conflict = "mismatch"    -- off-mode co-loads a mismatched site       *)
(*                               without serialising.                      *)
(*   Conflict = "misattribute" -- on-mode routes one site's traffic        *)
(*                               through another's upstream. This is the   *)
(*                               shared-HttpAuthCache failure the gate in  *)
(*                               proxy_router_attribution_test.dart hunts  *)
(*                               for on-device: both sites present the     *)
(*                               same credential, so one site's egress is  *)
(*                               the other's proxy.                        *)
(*                                                                        *)
(* Hosted tabs (LIR-018, LIR-024) make the proxy a slot needs a variable:  *)
(* a slot runs as the site its active tab is hosted by, `ident[s]`, and    *)
(* every rule reads that identity's proxy, never the owning site's. A tab  *)
(* switch that changes the identity is a Rebind, and so is a link tab      *)
(* moved by its opener's routing switch (LIR-034): the visible slot        *)
(* serialises against its new identity first; a background slot is left   *)
(* unloaded and rebuilds on its next activation. Two more demonstrators:   *)
(*                                                                        *)
(*   Conflict = "staleident"  -- a background slot rebinds to a mismatched *)
(*                               identity and stays loaded.               *)
(*   Conflict = "sitenotslot" -- activation serialises by the sites'      *)
(*                               own proxies instead of what their slots  *)
(*                               run as.                                  *)
(*                                                                        *)
(* Standalone model (a fixed 3-site scenario; no shared kernel state),     *)
(* like archive.tla and renderer.tla.                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,         \* number of sites (TLC sets 3; proofs use abstract N)
    Proxies,   \* set of proxy configurations
    proxyOf,   \* per-site proxy assignment (a function Sites -> Proxies)
    Conflict,  \* "none" | "mismatch" | "misattribute" | "staleident" | "sitenotslot"
    Router     \* "off" (PROXY-008 serialisation) | "on" (PROXY-013 router)

Sites == 1..N

ASSUME ProxyTyping == proxyOf \in [Sites -> Proxies]

\* Concrete assignment for TLC (substituted via `proxyOf <- ProxyOfDef` in the
\* .cfg): sites 1 and 3 share a proxy, site 2 differs.
ProxyOfDef == << "direct", "socks", "direct" >>

VARIABLES
    active,   \* the visible site (its proxy is the native active proxy)
    loaded,   \* set of concurrently-loaded sites
    egress,   \* per site, the proxy its traffic ACTUALLY leaves through
    ident     \* per slot, the site it runs as (LIR-018: its active tab's host)

vars == << active, loaded, egress, ident >>

RouterOn == Router = "on"

Egresses == Proxies \cup {"none"}

TypeOK ==
    /\ active \in Sites
    /\ loaded \subseteq Sites
    /\ egress \in [Sites -> Egresses]
    /\ ident \in [Sites -> Sites]

\* The proxy a slot needs: its running identity's, not its owner's.
ProxyOfSlot(s) == proxyOf[ident[s]]

ActiveProxy == ProxyOfSlot(active)

\* Where each site's traffic goes, given the loaded set and the visible site.
\* Off-mode: everyone shares the single native slot, which carries the visible
\* site's proxy -- that is exactly why mismatched sites must not co-load.
\* On-mode: each site is routed by its own credential.
EgressFor(ld, act, id) ==
    [s \in Sites |->
        IF s \in ld
        THEN (IF RouterOn THEN proxyOf[id[s]] ELSE proxyOf[id[act]])
        ELSE "none"]

Init ==
    /\ active = 1
    /\ loaded = {1}
    /\ ident = [s \in Sites |-> s]
    /\ egress = EgressFor({1}, 1, ident)

\* Switch to s. Off-mode serialises by unloading every loaded site whose proxy
\* differs; on-mode keeps them, because the router no longer repoints anything.
Activate(s) ==
    /\ active' = s
    /\ loaded' = IF RouterOn
                 THEN loaded \cup {s}
                 ELSE { t \in (loaded \cup {s}) : ProxyOfSlot(t) = ProxyOfSlot(s) }
    /\ egress' = EgressFor(loaded', s, ident)
    /\ UNCHANGED ident

\* Background-load a site. Off-mode refuses a mismatched one; on-mode allows
\* any site, which is the concurrency PROXY-013 buys.
LoadAllowed(s) ==
    /\ s \notin loaded
    /\ RouterOn \/ ProxyOfSlot(s) = ActiveProxy
    /\ active' = active
    /\ loaded' = loaded \cup {s}
    /\ egress' = EgressFor(loaded', active, ident)
    /\ UNCHANGED ident

\* Unload a non-active site.
Unload(s) ==
    /\ s \in loaded
    /\ s # active
    /\ active' = active
    /\ loaded' = loaded \ {s}
    /\ egress' = EgressFor(loaded', active, ident)
    /\ UNCHANGED ident

\* LIR-024: the visible slot switches to a tab that runs as i. Off-mode runs
\* PROXY-008 against the new identity before the rebuild, so every other
\* slot that now mismatches is unloaded.
RebindVisible(i) ==
    /\ ident' = [ident EXCEPT ![active] = i]
    /\ active' = active
    /\ loaded' = IF RouterOn
                 THEN loaded
                 ELSE { t \in loaded : proxyOf[ident'[t]] = proxyOf[i] }
    /\ egress' = EgressFor(loaded', active, ident')

\* LIR-024: a background slot switches to a tab that runs as i. Off-mode
\* leaves it unloaded; it rebuilds under i when next activated.
RebindBackground(s, i) ==
    /\ s # active
    /\ ident' = [ident EXCEPT ![s] = i]
    /\ active' = active
    /\ loaded' = IF RouterOn THEN loaded ELSE loaded \ {s}
    /\ egress' = EgressFor(loaded', active, ident')

\* Demonstrator (off-mode): co-load a proxy-MISMATCHED site without
\* serialising. Its traffic then leaves through the visible site's proxy.
LoadMismatched(s) ==
    /\ ~RouterOn
    /\ s \notin loaded
    /\ ProxyOfSlot(s) # ActiveProxy
    /\ active' = active
    /\ loaded' = loaded \cup {s}
    /\ egress' = EgressFor(loaded', active, ident)
    /\ UNCHANGED ident

\* Demonstrator (on-mode): the router attributes s's connection to t's
\* credential, so s leaves through t's upstream. This is what a shared
\* HttpAuthCache produces.
Misattribute(s, t) ==
    /\ RouterOn
    /\ s \in loaded
    /\ t \in loaded
    /\ ProxyOfSlot(s) # ProxyOfSlot(t)
    /\ active' = active
    /\ loaded' = loaded
    /\ egress' = [egress EXCEPT ![s] = ProxyOfSlot(t)]
    /\ UNCHANGED ident

\* Demonstrator (off-mode): a background slot rebinds to a mismatched
\* identity and stays loaded, so the new identity leaves through the visible
\* slot's proxy.
RebindBackgroundStale(s, i) ==
    /\ ~RouterOn
    /\ s # active
    /\ s \in loaded
    /\ ident' = [ident EXCEPT ![s] = i]
    /\ active' = active
    /\ loaded' = loaded
    /\ egress' = EgressFor(loaded', active, ident')

\* Demonstrator (off-mode): activation serialises by each site's own proxy,
\* as a check handed the site list instead of the slot identities would.
ActivateBySite(s) ==
    /\ ~RouterOn
    /\ active' = s
    /\ loaded' = { t \in (loaded \cup {s}) : proxyOf[t] = proxyOf[s] }
    /\ egress' = EgressFor(loaded', s, ident)
    /\ UNCHANGED ident

GoodNext ==
    \/ \E s \in Sites : Activate(s)
    \/ \E s \in Sites : LoadAllowed(s)
    \/ \E s \in Sites : Unload(s)
    \/ \E i \in Sites : RebindVisible(i)
    \/ \E s, i \in Sites : RebindBackground(s, i)

Next ==
    \/ GoodNext
    \/ (Conflict = "mismatch" /\ \E s \in Sites : LoadMismatched(s))
    \/ (Conflict = "misattribute" /\ \E s, t \in Sites : Misattribute(s, t))
    \/ (Conflict = "staleident" /\ \E s, i \in Sites : RebindBackgroundStale(s, i))
    \/ (Conflict = "sitenotslot" /\ \E s \in Sites : ActivateBySite(s))

Spec == Init /\ [][Next]_vars

\* SAFETY (both modes): every loaded slot egresses through the proxy of the
\* site it runs as. Broken by "mismatch", "staleident" and "sitenotslot"
\* (off) and by "misattribute" (on).
Inv_EgressMatchesConfig == \A s \in loaded : egress[s] = ProxyOfSlot(s)

\* SAFETY (off-mode only): every loaded slot shares the active slot's proxy.
\* This is PROXY-008's mechanism; under the router it is false by design.
Inv_ProxyCoherent == \A s \in loaded : ProxyOfSlot(s) = ActiveProxy

\* SAFETY: the active site is loaded.
Inv_ActiveLoaded == active \in loaded

\* Anti-vacuity witness (expect violated): two proxy-compatible sites can be
\* loaded together, so coherence is checked against real multi-site loading.
Reach_TwoLoaded == ~(Cardinality(loaded) >= 2)

\* Anti-vacuity witness. Under the router (expect VIOLATED) two sites with
\* DIFFERENT proxies co-load -- the cold start PROXY-008 charged is gone.
\* Under serialisation the same formula must HOLD: it is the concurrency the
\* router adds, stated once and checked from both sides.
Reach_MismatchedCoLoaded ==
    ~(\E s, t \in loaded : ProxyOfSlot(s) # ProxyOfSlot(t))

\* Anti-vacuity witness (expect violated, both modes): a slot running as
\* another site is loaded beside that site's own slot (LIR-018).
Reach_HostedCoLoaded ==
    ~(\E s \in loaded : ident[s] # s /\ ident[s] \in loaded)
=============================================================================
