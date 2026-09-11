------------------------- MODULE proxy_coherent -------------------------
(***************************************************************************)
(* TLAPS proof that per-site proxy routing is correct for ANY number of     *)
(* sites, ANY proxy assignment, and BOTH Android designs. TLC checks N = 3  *)
(* with a fixed assignment; this is the unbounded backstop.                 *)
(*                                                                         *)
(* The property proved unconditionally is Inv_EgressMatchesConfig: every    *)
(* loaded site egresses through the proxy IT was configured with. That is   *)
(* what the user asked for, and it holds under PROXY-008 serialisation and  *)
(* under the PROXY-013 router alike.                                       *)
(*                                                                         *)
(* Inv_ProxyCoherent (every loaded site shares the ACTIVE proxy) is only    *)
(* serialisation's mechanism for getting there. Under the router it is      *)
(* false by design — mismatched sites co-load — so it is proved under the   *)
(* hypothesis Router = "off" rather than outright.                          *)
(*                                                                         *)
(* Note the shape of the induction: off-mode needs coherence as a conjunct  *)
(* to carry Inv_EgressMatchesConfig, because there every loaded site's      *)
(* egress is the VISIBLE site's proxy, so "each site egresses through its   *)
(* own" only follows once they are known to agree. On-mode carries it       *)
(* directly. One inductive invariant covers both.                          *)
(***************************************************************************)
EXTENDS proxy, TLAPS

ASSUME NAssumption == N \in Nat \ {0}
ASSUME RouterTyping == Router \in {"off", "on"}

GoodSpec == Init /\ [][GoodNext]_vars

Coherence == Router = "off" => Inv_ProxyCoherent

IndInv == TypeOK /\ Coherence /\ Inv_EgressMatchesConfig

USE NAssumption, ProxyTyping, RouterTyping

LEMMA InitInd == Init => IndInv
  BY DEF Init, IndInv, TypeOK, Coherence, Inv_ProxyCoherent,
         Inv_EgressMatchesConfig, ActiveProxy, EgressFor, Egresses, RouterOn,
         Sites

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Coherence, Inv_ProxyCoherent,
              Inv_EgressMatchesConfig, ActiveProxy, EgressFor, Egresses,
              RouterOn
  <1>1. CASE GoodNext
    <2>1. CASE \E s \in Sites : Activate(s)
      BY <2>1 DEF Activate
    <2>2. CASE \E s \in Sites : LoadAllowed(s)
      BY <2>2 DEF LoadAllowed
    <2>3. CASE \E s \in Sites : Unload(s)
      BY <2>3 DEF Unload
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

LEMMA Inductive == GoodSpec => []IndInv
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1> QED
    BY <1>1, <1>2, PTL DEF GoodSpec

\* The property that survives both designs.
THEOREM EgressMatchesConfig == GoodSpec => []Inv_EgressMatchesConfig
  <1>1. IndInv => Inv_EgressMatchesConfig
    BY DEF IndInv
  <1> QED
    BY Inductive, <1>1, PTL

\* Serialisation's mechanism, asserted only where it is meant to hold.
THEOREM Coherent == GoodSpec => [](Router = "off" => Inv_ProxyCoherent)
  <1>1. IndInv => Coherence
    BY DEF IndInv
  <1> QED
    BY Inductive, <1>1, PTL DEF Coherence
=============================================================================
