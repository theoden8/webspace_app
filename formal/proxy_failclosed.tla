------------------------ MODULE proxy_failclosed ------------------------
(***************************************************************************)
(* Proxy fail-closed: a site configured with a non-DEFAULT proxy never       *)
(* egresses directly. When the proxy config is malformed / un-buildable      *)
(* (an empty or bad address from a hand-edited backup, or a native apply     *)
(* failure), the good engine blanks the load (no egress) rather than         *)
(* falling back to a direct connection over the device IP.                   *)
(*                                                                          *)
(*   Inv_NoDirectWhenProxied == a proxied site never has a direct egress    *)
(*                                                                          *)
(* The "failopen" demonstrator falls back to direct when the proxy can't be  *)
(* built (the old empty-address / swallowed-throw / null->direct behavior)   *)
(* and is caught. A config change resets egress (the webview is rebuilt to   *)
(* pick up a new proxy), so there is no stale direct egress. Standalone.     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Conflict   \* "none" | "failopen"

VARIABLES
    proxyType,   \* "default" | "proxied"
    buildable,   \* whether the configured proxy is well-formed / applicable
    egress       \* "none" | "direct" | "proxied"

vars == << proxyType, buildable, egress >>

TypeOK ==
    /\ proxyType \in {"default", "proxied"}
    /\ buildable \in BOOLEAN
    /\ egress \in {"none", "direct", "proxied"}

Init ==
    /\ proxyType = "default"
    /\ buildable = TRUE
    /\ egress = "none"

\* A config change rebuilds the webview, so egress is cleared until the next
\* load re-establishes it (no stale direct egress across a proxy change).
SetDefault ==
    /\ proxyType' = "default"
    /\ buildable' = TRUE
    /\ egress' = "none"

SetProxied(b) ==
    /\ proxyType' = "proxied"
    /\ buildable' = b
    /\ egress' = "none"

\* GOOD load: default -> direct (no proxy configured, fine); proxied +
\* buildable -> proxied; proxied + not buildable -> blank (no egress),
\* i.e. fail closed.
Load ==
    /\ egress' = (IF proxyType = "default" THEN "direct"
                  ELSE IF buildable THEN "proxied"
                  ELSE "none")
    /\ proxyType' = proxyType
    /\ buildable' = buildable

\* Demonstrator: a proxied-but-unbuildable config falls back to a direct
\* connection (the leak).
LoadFailOpen ==
    /\ proxyType = "proxied"
    /\ ~buildable
    /\ egress' = "direct"
    /\ proxyType' = proxyType
    /\ buildable' = buildable

GoodNext ==
    \/ SetDefault
    \/ \E b \in BOOLEAN : SetProxied(b)
    \/ Load

Next == GoodNext \/ (Conflict = "failopen" /\ LoadFailOpen)

Spec == Init /\ [][Next]_vars

\* SAFETY: a proxied site never egresses directly. Broken by "failopen".
Inv_NoDirectWhenProxied == (proxyType = "proxied") => (egress # "direct")

\* Anti-vacuity witness (expect violated): a proxied egress is reachable, so
\* the good path really does proxy (not just block everything).
Reach_Proxied == egress # "proxied"
=============================================================================
