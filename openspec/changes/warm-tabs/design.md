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

- A switch to a warm tab does no await: it shows the webview it already has.
- The caps bound live webviews with the same numbers as today.
- One owner for "which webviews stay": the residency plan, with warm tabs as
  more candidates in it, never a second eviction path for tabs.

**Non-Goals:**

- Warming a tab the user has not been on: a tab becomes warm only by being
  left. "Open in new tab" still creates a parked tab.
- A user setting for the limit.
- Changing the numbers of either cap.

## Decisions

### D1. The unit is the live webview

A live webview is named by `LiveView = ({SiteId owner, TabId tab})`: the slot
it mounts in and the tab it was built for. `loaded`, the LRU order, the
lifecycle tiers and the eviction candidates are over `LiveView`s. A site is
loaded while any of its `LiveView`s is.

Alternative: keep the site as the unit and let warm tabs ride outside the
caps. Rejected: the bound stops being a bound, and two pickers (sites, then
tabs) would decide one question.

### D2. Retention tiers below `loaded`

`SiteRetentionPriority` gains four values below `loaded`, so `evictionOrder`
needs no other change:

| Tier | Webview |
|---|---|
| `warmOnScreen` | a warm own tab listed under the site on screen |
| `warmOnScreenHosted` | a warm hosted tab listed under the site on screen |
| `warmOwn` | a warm tab of another site, in its own list |
| `warmHosted` | a warm tab of another site, hosted (runs as another site) |

Enum order is eviction order (TAB-024), and within a tier `evictionOrder`
keeps the LRU order it is given.

### D3. The warm limit is a plan rule, read per running site

`3 + min(hosted, 2)` (TAB-023) is a rule of the residency plan, applied on the
event a tab goes warm on (`TabLeft`, a new `ResidencyEvent`), before the cap
rule. It groups `LiveView`s by running identity (`SlotIdentities`, LIR-024,
extended from slots to views) and picks overflow hosted-first, then LRU. The
cap rule then sees the loaded set the limit leaves, as each rule sees what
the rules before it leave today.

### D4. A switch

- **Warm target:** one turn, no await: the active tab goes warm (pause, end
  its capture), the target becomes active and is shown. No bytes move.
- **Parked target:** read its bytes (the await that exists today), then one
  turn: the active tab goes warm, the target becomes active, its bytes are
  queued tagged with its tab, a webview is built for it. Then the plan runs
  for `TabLeft`; if it takes the tab just left, that tab is captured and
  disposed by the unload flow, as D3 of `inactive-tabs` did inline.

`WebViewTabBinding` becomes per tab: `built` is the set of tabs with a live
webview; the queued bytes keep their tab tag (TAB-003, BUG-036 unchanged).

### D5. The model

`built[s]` becomes a subset of `tabs[s]`. `Inv_TabBound` becomes
`built[s] \subseteq tabs[s]` with `active[s] \in built[s]` while the site is
loaded; `Inv_TabShown` becomes "each built tab's webview shows its own tab's
history". The warm eviction is the unload flow over a `LiveView`, nested as
today, so its capture's two awaits are the existing `captureSteps`. It shares
`hist`, `file` and `built` with the tab flow, so the two are checked together
(footprints). The model keeps a constant `MaxWarm` of 1 by default so the state
space grows by one warm tab per site; a config with 2 checks the hosted rule.

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
`KeyedSubtree` per live tab, keyed by `TabId`, the shown one on top. A slot
with no active webview and a warm hosted tab still mounts (TAB-026).

### D8. Unloads by running site

Domain conflict, proxy mismatch and Tor exit mismatch already judge a slot by
the identity it runs as (LIR-024). They judge each `LiveView` by its own
running identity, and an unload of a site takes every view running as it
(TAB-027). Under the legacy jar the cookie capture runs once, after the last
of those views is disposed, so the jar is read after no view of the site can
write it.

### D9. Persistence

Warm is runtime state: nothing persisted changes. The paths that capture the
active tab on going home and on app background (PAUSE-009) iterate the site's
live views (TAB-028).

## Risks / Trade-offs

- [Interleavings: every warm view is another candidate for every plan] →
  `MaxWarm` 1 in the base model, 2 in one world; name the base config's
  `Finished in` before and after, as a new step on a hot flow requires.
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
