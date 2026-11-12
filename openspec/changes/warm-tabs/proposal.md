## Why

Every tab switch inside a site reloads the page: the one webview a site may hold
(TAB-002) is disposed and rebuilt, so scroll position, form input and an app's
own state are lost, even when most of the loaded-site budget (`kMaxLoadedSites`,
20) is unused. A site switch reloads only past that cap or under memory
pressure. The cost of a reload is paid where memory is plentiful.

The caps count sites, but memory is spent per webview. Measured on WPE WebKit
2.54 (six Wikipedia pages, headless):

| Layout | Web processes | Total PSS | Load of pages 2 to 6 |
|---|---|---|---|
| one site, six tabs (one network session) | 6 | 1602 MB | 1.65 s |
| six sites (a session each) | 6 | 1627 MB | 2.6 s |

Each webview is its own web process whether or not it shares a site; a
container adds about 6.5 MB of network process. A second webview of a site
costs what a second site costs, so the caps can count webviews and let a site
keep more than one tab live without raising the bound.

## What Changes

- **The caps count webviews.** `kMaxLoadedSites` (20) and `kMaxResidentSites`
  (10) bound live webviews, not sites. The worst-case memory is unchanged.
- **A tab can be warm**: inactive, not shown, with its webview kept live and
  paused. Switching to a warm tab shows it, with no capture, dispose or
  reload. A tab with no webview is parked, as today.
- **Warm tabs per running site: `3 + min(hosted, 2)`.** At most 3 in the
  site's own tab list, at most 5 in all, where `hosted` counts the site's warm
  tabs listed under other sites. Over the limit, the site's least recently
  used hosted tab goes, an own tab only when no hosted one is warm.
- **Warm tabs are evicted first.** Under either cap and under memory pressure:
  warm hosted tabs of other sites, then warm own tabs of other sites, then
  warm tabs listed under the site on screen, then active webviews by their
  current tiers. Least recently used first within each.
- **Only the active tab acts as the site.** A tab that goes warm is paused and
  loses camera, microphone and screen capture; background audio and
  notification polling stay with the active tab.
- **A hosted tab can stay warm.** It counts toward, and is judged as, the site
  it runs as (LIR-018): an unload of that site for a domain conflict, proxy
  mismatch or Tor exit mismatch takes it, wherever it is listed. It mounts in
  its owner's slot, which may hold warm webviews while its own is unloaded.
- **Both isolation engines.** Tabs of a site share its cookies under the
  legacy shared jar too; an unload of a site takes every webview running as
  it, and the jar is captured once per site, as today.
- **BREAKING (spec):** TAB-002's "at most one live webview per site" and
  TAB-011's "a tab is loaded exactly when it is the active tab" are replaced.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `inactive-tabs` (in flight in `inactive-tabs`): TAB-002 and TAB-011
  rewritten for warm tabs; new requirements for the warm limit, the eviction
  order, what a warm tab may do, hosted warm tabs, and unloads by running site.
- `webview-pause-lifecycle`: PAUSE-006 (memory-pressure cascade) and PAUSE-012
  (proactive cache clear) count and pick webviews, warm tabs first.
- `per-site-containers`: CONT-003's LRU backstop bounds webviews.

## Impact

- **Engines:** `SiteUnloadEngine` (the LRU cap's unit, the conflict unloads),
  `SiteLifecyclePromotionEngine` (tiers per webview), `SiteRetentionPriority`
  (two warm tiers), the tab tables (`TabTable.tabInputs`, `tabFlow`: a switch
  to a warm tab, a warm tab's eviction).
- **Runtime state:** `WebViewTabBinding.built` becomes the set of tabs with a
  live webview, one of them shown; `RuntimeVars.loaded` is read per webview.
  Both are joins in the CLAUDE.md map, flagged for review.
- **Model:** `formal/activation.tla` gets `built[s]` as a set and a warm-tab
  eviction flow sharing `hist`, `file` and `built` with the tab flow;
  `Inv_TabBound` and `Inv_TabShown` restated; `formal/retention.tla` gets the
  warm tiers.
- **UI:** the site's slot under `ValueKey(siteId)` holds one subtree per live
  tab; the Tabs sheet shows a warm tab at full strength (TAB-011).
- **Unmeasured:** Android, where every webview shares one renderer process,
  and Apple. The bound holds either way, since warm tabs only take budget the
  sites leave free.
