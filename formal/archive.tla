---------------------------- MODULE archive ----------------------------
(***************************************************************************)
(* ARCH-001 active-state byte-identity, formalized.                        *)
(*                                                                         *)
(* The spec requires app-tier persisted state to be BYTE-IDENTICAL whether *)
(* the device has zero or N archives (all closed). That is a 2-safety      *)
(* HYPERPROPERTY -- it relates two executions, not states of one -- so it  *)
(* does NOT fit the single-execution kernel. The standard encoding is      *)
(* SELF-COMPOSITION: run both worlds in lockstep on the same app-tier      *)
(* actions and assert their app-tier state never diverges.                 *)
(*                                                                         *)
(*   world A: archives may be created/closed                               *)
(*   world B: never has archives                                           *)
(*                                                                         *)
(* ByteIdentity == appA = appB must hold for every reachable state. The    *)
(* Leak demonstrator writes the archive count into app-tier state (a       *)
(* forbidden "counter / flag / feature-touched marker that varies with     *)
(* archive presence") and is caught.                                       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxSteps,  \* bound on app-tier writes (finite state space)
    MaxArch,   \* bound on archives created in world A
    Leak       \* TRUE pulls in the demonstrator that leaks archive count into app-tier state

VARIABLES
    appA,   \* app-tier persisted state in world A (has archives)
    appB,   \* app-tier persisted state in world B (no archives)
    nArch,  \* archives created in world A
    steps   \* app-tier writes so far

vars == << appA, appB, nArch, steps >>

TypeOK ==
    /\ appA \in Nat
    /\ appB \in Nat
    /\ nArch \in 0..MaxArch
    /\ steps \in 0..MaxSteps

Init ==
    /\ appA = 0
    /\ appB = 0
    /\ nArch = 0
    /\ steps = 0

\* An app-tier write (add a site, change a global pref). Identical effect in
\* BOTH worlds and independent of archive state -- this is the app-tier
\* collection that settings export/import operates on.
AppWrite ==
    /\ steps < MaxSteps
    /\ steps' = steps + 1
    /\ appA' = appA + 1
    /\ appB' = appB + 1
    /\ nArch' = nArch

\* Archive lifecycle (create / close) -- world A only. ARCH-001: it MUST NOT
\* perturb app-tier persisted state. The Leak demonstrator violates this by
\* folding the archive count into app-tier state.
ArchiveLifecycle ==
    /\ nArch < MaxArch
    /\ nArch' = nArch + 1
    /\ appB' = appB
    /\ steps' = steps
    /\ IF Leak THEN appA' = appA + nArch + 1   \* FORBIDDEN: archive presence leaks
               ELSE appA' = appA               \* correct: app-tier state untouched

Next == AppWrite \/ ArchiveLifecycle
Spec == Init /\ [][Next]_vars

\* ARCH-001 byte-identity via self-composition: the app-tier state is identical
\* regardless of archive count.
ByteIdentity == appA = appB

\* Anti-vacuity witness (expect violated): a state with archives created AND an
\* app-tier write is reachable, so ByteIdentity is checked against real activity
\* rather than holding because nothing happens.
Reach_Active == ~(nArch >= 1 /\ steps >= 1)
=============================================================================
