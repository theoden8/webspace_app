## Context

`inactive-tabs` gives a site one webview, bound to its active tab
(design D2, TAB-002), and makes a tab switch a capture, dispose, rebuild and
restore (D3). D3 named "a warm second webview" as the future tier if switches
turned out to cost too much. Proposal.md (Why) has the measurement that
answers it: a webview costs the same whether or not it shares a site, so the
bound the caps give is a bound on webviews.

What holds the one-webview rule today:

| Where | What it assumes |
|---|---|
| `SiteRetentionPriority`, `evictionOrder` | a candidate is a site row |
| `SiteUnloadEngine.plan`, `indicesToEvictForLruCap` | the LRU unit is a site; `loaded` is a set of sites |
| `SiteLifecyclePromotionEngine` | a tier per site |
| `WebViewTabBinding` | `built` is one `TabId` or none |
| `formal/activation.tla` | `Inv_TabBound`: `built[s] \in {0, active[s]}`; `Inv_TabShown`: `hist[s] = built[s]` |
| `WebViewModel.pauseWebView` | skips notification and background-audio sites, so they keep running in the background |
| the site's slot | one child under `ValueKey(siteId)`, keyed by `activeTabId` |

## Goals / Non-Goals

**Goals:**

- A switch to a warm tab shows the webview it already has: no read of its
  bytes, no build, no reload. It still waits for the capture of the tab it
  leaves, as every switch does today.
- The caps bound live webviews with the same numbers as today.
- One owner for "which webviews stay": the residency plan, with warm tabs as
  more candidates in it, never a second eviction path for tabs.

**Non-Goals:**

- Warming a tab the user has not been on: a tab becomes warm only by being
  left. "Open in new tab" still creates a parked tab.
- A user setting for the limit.
- Changing the numbers of either cap.

## Decisions

### D1. The unit is the live webview, counted beside the sites

A site's views are its shown one and its warm ones, owned by one class,
`SiteViews` (`lib/web_view_model_site_views.dart`): only its methods move a view between
shown and warm, so no view is both. A warm view is named by a `WarmUnit`,
its site and its tab. `loaded` stays a set of sites; the loaded-site cap
counts `Cardinality(loaded) + Cardinality(WarmUnits(loaded))` (D5).

Alternative: retype `loaded` to views. Rejected: 37 readers, and the base
world, which follows no tabs, would carry them.

### D2. The order is a function over warm views, not new retention tiers

`SiteRetentionPriority` stays a ranking of sites. Warm views are not sites,
so TAB-024's order is `SiteUnloadEngine.inDropOrder`: warm views of sites
not on screen first, then the on-screen site's, hosted before own, least
recently used first. The cap and memory pressure take warm views through it
before any site, and only then pick sites by retention priority as today.
The model takes any warm view where the code takes the first in this order
(`Expr.chosen` / `choices`), and `formal/retention.tla` checks the order
itself.

### D3. The limit, the cap and a joining site, in the switch's turn

`3 + min(hosted, 2)` (TAB-023) is per slot, and a slot keeps warm only views
running as the site its shown tab runs as, so a slot's views share one route
and one Tor exit and the proxy rules need no change. The switch lets the
slot's least recently used warm view go (hosted first) when keeping it would
pass the limit, the loaded-site cap, or while a tap or a preload is about to
add a site its plan counted without that view (`WarmOver`). The activation's
plan drops the warm views its cap needs in its own turn, as a pair with the
sites it picks (`cross` of two `choices`).

### D4. A switch

Every switch captures the tab it leaves first, as today (TAB-028), so a
warm tab's file is current from the moment it goes warm and disposing a warm
view never awaits a capture.

- **Warm target:** after the capture, one turn: the active tab goes warm
  (pause, end its capture), the target becomes active and is shown. No bytes
  are read or queued.
- **Parked target:** after the capture, read its bytes (the await that exists
  today), then one turn: the active tab goes warm, the target becomes active,
  its bytes are queued tagged with its tab, a webview is built for it.

The same turn applies the warm limit (TAB-023): a warm view over it is
disposed, with nothing to await. A closed tab's view is disposed in the
close's turn, never left warm.

`WebViewTabBinding` keeps `built` (the shown view's tab) and gains the warm
views by tab; the queued bytes keep their tab tag (TAB-003, BUG-036
unchanged).

### D5. The model

`loaded` stays a set of sites, and `built[s]` and `hist[s]` keep meaning the
shown view exactly as today, so every existing write, invariant and proof case
prints as it does. One variable joins them: `warm[s] \in [TabIds -> TabIds
\cup {0}]`, the history label a live view of tab `t` shows while it is not
shown, 0 when `t` has none. It is no second owner: `built` says which tab the
shown view is for, `warm` which other views live. Alternatives: `built[s]` as
a set with `hist[s]` per tab (every printed write, invariant and TLAPS type
case changes), or retyping `loaded` to views (37 readers). Both rejected.

- **Writes.** The switch's one turn moves `hist[s]` into `warm[s][built[s]]`
  and, for a warm target, takes `hist[s]` from `warm[s][target]`; the same
  turn zeroes an entry over the limit. A close zeroes the closed tab's entry;
  an unload, delete, archive close or `LetGo` zeroes the row. Every action
  that writes `warm` already writes `built` or `hist`, so no pair of flows
  shares a variable it did not share before: `activation_footprints.tsv`'s
  sharing pairs must not grow, and `printWorlds` prints no new world.
- **Only over `Tabbed`**, as `built`: 0 for a site the model does not follow,
  never written there. The base `activation.cfg` (`Tabbed = {}`) reports the
  same number of distinct states before and after.
- **Named once**, as a `ModelVar`, its leaf the code's live views per tab
  (`WebViewTabBinding`, through `TabVars`), so the printer writes it into
  every frame, the facts proofs and the replay. The hand-written environment
  actions take it by hand.
- **The warm views as printed operators**: `WarmTabs(s)`, a slot's warm
  tabs, and `WarmUnits(S)`, the pairs `<<s, t>>` over a set of sites, each a
  `Def` in `TabVars`. The cap's count, TAB-023's limit (`WarmOver`) and the
  plans' picks read them, never `warm` apart.
- **Invariants**, each with its own planted mistake:

| Invariant | Mutant | World |
|---|---|---|
| `Inv_WarmShown`: `warm[s][t] \in {0, t}` | the switch stores `built[s]` instead of `hist[s]` | a build in flight at a switch |
| `Inv_WarmListed`: `warm[s][t] # 0 => t \in tabs[s] /\ t # active[s]` | a close leaves the closed tab's entry | a close of a warm tab |
| `Inv_WarmLoaded`: `warm[s][t] # 0 => s \in loaded` | an unload or delete leaves the row | pressure or a delete with a warm tab |

Worlds:

| World | Warm | Checks |
|---|---|---|
| the printed tab worlds (`Tabbed = {1}`, `MaxTabs = 3`) | `WarmOwn = 3`, `WarmHosted = 2` | the active tab against a warm one: a switch landing after a capture, a close of the tab being captured, the queued bytes' tag (TAB-003, BUG-036) |
| `tabs_warm_one`, `Tabbed = {1}`, `MaxTabs = 3` | a limit of one | two warm tabs: the limit's choice between them (TAB-023) |
| `tabs_cap_two`, the cap at two | the limits as shipped | an unload of a site takes the warm view running as it (TAB-026, TAB-027) |
| the base world (`Tabbed = {}`) | none | unchanged: the same distinct states |

The cost to watch is the costliest tab world,
`activation_gen_jar_cold_tabs_reset_one` (15,094 worker-seconds on master):
a switch to a warm tab is a new one-turn arm against the capture's two awaits.

### D6. A warm tab acts as nothing

Going warm pauses the view regardless of the site's notification or
background-audio switch: `pauseWebView` grows a per-view form that skips the
early returns, since those exist so the site keeps running, and the site keeps
running in its active tab. Capture ends per view (`ScreenShare.endView`, the
media capture's per-view stop). The notification bridge drops a post from a
view that is not its site's active one, at the handler, so a page cannot go
around it.

### D7. The slot

The site's slot keeps its `ValueKey(siteId)` (WEBSPACE-011) and holds one
`KeyedSubtree` per live tab, keyed by `TabId`, the shown one on top. An
unloaded slot holds none (TAB-026).

### D8. Unloads by running site

Domain conflict, proxy mismatch and Tor exit mismatch already judge a slot by
the identity it runs as (LIR-024). A slot's warm views run as that identity
(D3), so the slot's judgment covers them, and an unload of a site takes every
view of its slot (TAB-027): `LetGo` and the unload's dispose zero its `warm`
row with `built`. Under the legacy jar the cookie capture runs once, after the last
of those views is disposed, so the jar is read after no view of the site can
write it.

### D9. Persistence

Warm is runtime state: nothing persisted changes. A warm tab's file was
written as it went warm (TAB-028), so going home and the app going to the
background (PAUSE-009) capture the active tab only, as today.

## Risks / Trade-offs

- [Interleavings: a switch to a warm tab is a new one-turn arm against the
  capture's two awaits] → `MaxWarm` 1 in the printed tab worlds and 2 in one
  written world; name the `Finished in` of
  `activation_gen_jar_cold_tabs_reset_one`, the costliest tab world (15,094 s
  on master), before and after, and look at that arm first if it grows past
  about 10%.
- [Android: JS timers of a paused view keep running, since `onPause` is per
  view and `pauseTimers` is process-wide] → the same as a background site
  today; warm tabs go first under pressure.
- [iOS: more WebContent processes alive raises jetsam risk] → the cap's number
  is unchanged, so the worst case is twenty processes as today.
- [The hosted rule surprises: a GitHub tab under Mastodon can push out
  another GitHub tab under Mastodon] → only hosted ones; own tabs are kept
  (TAB-023).
- [Unmeasured on Android and Apple] → measure before archiving (tasks).

## Migration Plan

No data migration. The warm limit is a constant; at 0 the plan takes every
tab left, which is today's behaviour, so setting it to 0 rolls the feature
back without reverting code. `inactive-tabs` is archived before this change,
since this change's deltas modify its requirements.

## Open Questions

- Whether Android's single renderer process changes the cost per webview
  enough to want a lower cap there. It would change a constant, not the
  design.
