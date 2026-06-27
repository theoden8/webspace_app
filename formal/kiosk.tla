----------------------------- MODULE kiosk -----------------------------
(***************************************************************************)
(* Kiosk mode (spec: kiosk-mode). A site launched from a home-screen       *)
(* shortcut with kioskMode = TRUE seals the app shell: the drawer is not    *)
(* built, the tab strip and app-bar actions are hidden, and the session is  *)
(* fullscreen with no exit affordance -- only the webview is shown. The     *)
(* lock is derived SOLELY from the launch source: a plain launch (launcher  *)
(* icon) or a shortcut to a non-kiosk site does NOT lock. A warm resume     *)
(* (process intact) keeps whatever lock the launch established              *)
(* (session-sticky); opening the app normally is the only exit.            *)
(*                                                                         *)
(*   Inv_LockedIsSealed    == locked => chrome fully suppressed AND         *)
(*                            fullscreen held              (KIOSK-002/003)  *)
(*   Inv_LockMatchesSource == locked <=> last launch was a kiosk shortcut   *)
(*                                                          (KIOSK-001)     *)
(*                                                                         *)
(* Negative demonstrators (MUST be caught):                                 *)
(*   "exitfs" -- exiting fullscreen while locked (_exitFullscreen forgets   *)
(*               to early-return)                                           *)
(*   "chrome" -- building the drawer while locked                          *)
(* Positive witness (MUST be reachable): a locked state. Standalone model   *)
(* (no shared kernel state), like proxy.tla and renderer.tla.              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    N,         \* number of sites (TLC sets 2; site 1 kiosk, site 2 not)
    kioskOf,   \* per-site kioskMode flag (a function Sites -> BOOLEAN)
    Conflict   \* "none" | "exitfs" | "chrome"

Sites == 1..N

ASSUME KioskTyping == kioskOf \in [Sites -> BOOLEAN]

\* Concrete assignment for TLC (substituted via `kioskOf <- KioskOfDef`):
\* site 1 is a kiosk site, site 2 is not.
KioskOfDef == << TRUE, FALSE >>

VARIABLES
    launched,       \* a launch has happened
    locked,         \* the shell is sealed
    kioskShortcut,  \* the last launch was a shortcut to a kiosk site
    fullscreen,     \* the session is fullscreen
    drawerBuilt,    \* the navigation drawer is attached to the scaffold
    tabStrip,       \* the bottom tab strip is shown
    appBarActions   \* the app-bar action buttons / leading menu are shown

vars == << launched, locked, kioskShortcut, fullscreen,
           drawerBuilt, tabStrip, appBarActions >>

TypeOK ==
    /\ launched \in BOOLEAN
    /\ locked \in BOOLEAN
    /\ kioskShortcut \in BOOLEAN
    /\ fullscreen \in BOOLEAN
    /\ drawerBuilt \in BOOLEAN
    /\ tabStrip \in BOOLEAN
    /\ appBarActions \in BOOLEAN

\* Pre-launch: nothing rendered, unlocked.
Init ==
    /\ launched = FALSE
    /\ locked = FALSE
    /\ kioskShortcut = FALSE
    /\ fullscreen = FALSE
    /\ drawerBuilt = FALSE
    /\ tabStrip = FALSE
    /\ appBarActions = FALSE

\* The unlocked shell: drawer / tab strip / app-bar actions all available and
\* not forced fullscreen. Rendering beyond the lock is abstracted to "shown".
UnlockedShell ==
    /\ locked' = FALSE
    /\ kioskShortcut' = FALSE
    /\ fullscreen' = FALSE
    /\ drawerBuilt' = TRUE
    /\ tabStrip' = TRUE
    /\ appBarActions' = TRUE

\* The locked shell (KIOSK-002 + KIOSK-003): drawer not built, tab strip and
\* app-bar actions hidden, fullscreen forced, no exit.
LockedShell ==
    /\ locked' = TRUE
    /\ kioskShortcut' = TRUE
    /\ fullscreen' = TRUE
    /\ drawerBuilt' = FALSE
    /\ tabStrip' = FALSE
    /\ appBarActions' = FALSE

\* Cold/warm launch via a site's home-shortcut (KIOSK-001): lock iff the
\* target is a kiosk site.
LaunchShortcut(s) ==
    /\ launched' = TRUE
    /\ IF kioskOf[s] THEN LockedShell ELSE UnlockedShell

\* Plain launch from the launcher icon (no shortcut payload): never locks.
LaunchPlain ==
    /\ launched' = TRUE
    /\ UnlockedShell

\* Warm resume, process intact (paused -> resumed): no launch intent, so the
\* lock and the whole shell are unchanged (session-sticky, KIOSK-001).
Resume ==
    /\ launched = TRUE
    /\ UNCHANGED vars

\* Good no-op: an exit-fullscreen attempt while locked does nothing
\* (_exitFullscreen early-returns); the locked shell is held (KIOSK-003).
ExitAttemptNoop ==
    /\ locked = TRUE
    /\ UNCHANGED vars

\* Demonstrator "exitfs": leaving fullscreen while still locked (the broken
\* path where _exitFullscreen does not early-return). Violates sealing.
ExitFullscreenWhileLocked ==
    /\ locked = TRUE
    /\ fullscreen' = FALSE
    /\ UNCHANGED << launched, locked, kioskShortcut, drawerBuilt, tabStrip, appBarActions >>

\* Demonstrator "chrome": building the drawer while locked (the broken path
\* where `drawer:` is not nulled out under the lock). Violates sealing.
ShowChromeWhileLocked ==
    /\ locked = TRUE
    /\ drawerBuilt' = TRUE
    /\ UNCHANGED << launched, locked, kioskShortcut, fullscreen, tabStrip, appBarActions >>

GoodNext ==
    \/ \E s \in Sites : LaunchShortcut(s)
    \/ LaunchPlain
    \/ Resume
    \/ ExitAttemptNoop

Next ==
    \/ GoodNext
    \/ (Conflict = "exitfs" /\ ExitFullscreenWhileLocked)
    \/ (Conflict = "chrome" /\ ShowChromeWhileLocked)

Spec == Init /\ [][Next]_vars

\* SAFETY (KIOSK-002 + KIOSK-003): a locked session suppresses every chrome
\* affordance and holds fullscreen. Broken by "exitfs" and "chrome".
Inv_LockedIsSealed ==
    locked => /\ ~drawerBuilt
              /\ ~tabStrip
              /\ ~appBarActions
              /\ fullscreen

\* SAFETY (KIOSK-001): the lock is exactly the kiosk-shortcut launch source.
Inv_LockMatchesSource == locked <=> kioskShortcut

\* Anti-vacuity witness (expect violated): a locked state is reachable, so the
\* sealing invariant is checked against a real lock and not vacuously over an
\* all-unlocked state space.
Reach_Locked == ~locked
=============================================================================
