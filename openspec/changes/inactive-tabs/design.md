## Context

What exists today, in the terms this design has to fit:

- A **site** (`WebViewModel`) is one identity: a container `ws-<siteId>` (or
  the legacy shared jar), per-site settings, and one `currentUrl`/`pageTitle`.
  One `InAppWebView` per site, created lazily (LAZY-002), kept resident across
  site switches (LAZY-004), capped at `kMaxLoadedSites` (20) with a resident
  comfort limit of `kMaxResidentSites` (10) beyond which
  `SiteLifecyclePromotionEngine` walks a site
  `resident -> cacheCleared -> savedForRestore`.
- `savedForRestore` already is an inactive tab in everything but name: the
  webview is disposed, `controller.saveState()` bytes sit AES-encrypted in
  `<docs>/webview_state/<siteId>.enc` (`SecureWebViewStateStorage`, PAUSE-008),
  and the next activation rebuilds the webview and calls `restoreState`.
  Restore only applies to a freshly created webview: `queueNavStateRestore`
  refuses a live controller, and `getWebView` consumes the queued bytes in
  `onControllerCreated`. On Android the initial load is deferred so the bytes
  land on a pristine back/forward list and the top entry is then reloaded; on
  Apple the initial request runs and `interactionState` replaces the stack in
  place.
- NAV-004 Home already disposes and recreates the site's webview to get a
  clean history. The dispose-and-rebuild cost is a known, accepted one.
- The capture points are PAUSE-009 (go-home, app-background, navigation with a
  3 s trailing debounce) and the pairing rule is BUG-003's invariant: every
  path that keeps a webview across a restart pairs a capture before death with
  a restore queue before first build.
- A **cross-domain hop** with a gesture opens a nested `InAppWebViewScreen`
  (NESTED-004) that shares the site's container, carries its whole posture
  (NESTED-010), persists nothing, and pops when its own history runs out. It
  stays exactly like this in this round.
- On screen, the drawer grid and the bottom strip list **sites**, one chip
  each. There is no place a second page of a site could appear.

So the app has a per-site memory tier that looks exactly like a discarded tab
and no list to put a tab in. That list, and the two gestures that add to it,
are the whole feature.

## Derivation

1. **A tab belongs to a site and stays in its domain.** Every page renders
   inside one site's container and posture, so a tab belongs to a site. A tab
   is also restricted to the site's own domain (what `NavigationDecisionEngine`
   already allows in place, NESTED-007), so every tab of a site is in the same
   container by construction and the persisted `currentUrl` invariant (never a
   cross-origin URL, NESTED-005) holds for every tab. Cross-domain hops keep
   using the nested screen.
2. **One resident webview per site stays.** N live webviews per site would
   multiply renderer processes under a cap that is already tuned per site,
   re-open the same-base-domain conflicts the legacy engine serialises
   (ISO-001), and need a second copy of every lifecycle engine. Instead a
   site's tabs share its one webview: exactly one tab is active and bound to
   it; the rest are parked, which is `savedForRestore` keyed by tab. A parked
   tab is a record in prefs and one small file. Zero renderer, zero native
   objects.
3. **A tab switch is the tier walk, forced.** Activate T2 while T1 is active:
   `captureNavigationState()` for T1 into `store[site/T1]`, `disposeWebView()`,
   queue `store[site/T2]` (if any) via `schedulePendingRestoreState`, rebuild.
   Restore cannot be applied to a live controller, and Android's
   `restoreState` needs a pristine list, so the rebuild is not optional; it is
   also what Home already does. Peak footprint during a switch is zero
   webviews for that site, never two.
4. **Opening a site is not a tab event.** Tapping a site in the strip or the
   drawer, cold start, a shortcut, a share arrival: the site resumes its
   active tab, as a browser resumes the tab you were on. The alternative
   (start fresh every time) is what the app does today and turns every visit
   into one more tab. Two things create tabs, and both are explicit:
   - **New tab** (Tabs sheet header, both overflow menus): a root tab at
     `initUrl`, the current tab parks. A strip chip's long press is taken by
     the reorder drag, so it is not an entry point.
   - **Duplicate tab** (both overflow menus, long press on refresh): a parked
     copy of the current tab next to it, back stack included.
   - **Open in new tab** (long-press an in-domain link): a child tab of the
     current one, opened in the background with a snackbar to switch.
   Home (NAV-004) is the same tab going to `initUrl` with its history cleared.
5. **What survives is decided by direction.** Leaving a tab sideways (another
   tab, another site, the app itself) parks it. Leaving a child tab backwards,
   the system back gesture at the start of its history, closes it and returns
   to its parent. This is Chrome's rule for a tab opened from another tab, and
   it is the nested screen's rule today. Root tabs keep NAV-001's no-op. A tab
   you never scrolled and backed out of leaves no residue; a tab you left to
   do something else waits for you.
6. **The tree is free.** "Open in new tab" knows the tab it came from, so a
   tab records `parentId`, and one sheet renders every site's tabs indented by
   depth — tree-style tabs for the cost of a traversal. Closing a parent
   re-parents its children to the grandparent, so nothing is orphaned by a
   close.

## Goals / Non-Goals

**Goals**

- A site accumulates tabs without losing the one it is on.
- A tab survives sideways exits and app restarts; a backed-out child tab
  does not.
- One container and one resident webview per site; eviction, LRU and
  memory-pressure rules unchanged and unaware of tabs.
- Reuse: `SecureWebViewStateStorage`, the `savedForRestore` walk, the
  `onControllerCreated` restore queue, the NAV-004 rebuild.
- Every per-site feature that touches `currentUrl` or on-disk state gets an
  explicit answer for tabs (audit table below).

**Non-Goals (this round)**

- Share arrivals and `webspace://` opens as tabs.
- In-app taps on links another site claims.
- Cross-domain tabs or a nested screen backed by a tab.
- Keep limits, pins, sweeping.
- A warm second webview per site (the tab just switched from staying live
  for a few seconds). Could be a later tier behind the same model.
- Cross-site trees.

## Decisions

### D1. Tab model on the site

```dart
class SiteTab {
  final String id;          // path-safe token, same pattern as siteId
  String url;               // always inside the site's domain
  String? title;
  String? parentId;         // tab it was opened from, same site only
  DateTime createdAt;
  DateTime lastActiveAt;
}
// WebViewModel
List<SiteTab> tabs;         // creation order; tree is derived from parentId
String activeTabId;
String get currentUrl => activeTab.url;   // compatibility getter
```

`currentUrl` and `pageTitle` stay as getters over the active tab so the
existing persistence, always-home and incognito code keeps reading the same
names. Migration: JSON without `tabs` synthesises one root tab from
`currentUrl` (or `initUrl`) and makes it active; serialisation omits `tabs`
while it holds exactly that synthesised tab, so on-disk output is stable for
users who never open a second tab (same rule as LIR-001's `domainClaims`).

Alternative: global `Tab` objects with a `siteId`. Rejected: every consumer of
"the site's page" would have to look up the tab, and the archive tier's
byte-identity rule (ARCH-001) is far easier to hold when tabs ride the site's
own serialisation.

### D2. Memory contract: one container, one webview, parked tabs are bytes

Per site, always:

| Thing | Count | Where it lives |
|---|---|---|
| Container `ws-<siteId>` | 1 | native; shared by every tab of the site |
| `InAppWebView` + renderer | 0 or 1 | bound to the active tab; 0 when the site is unloaded or evicted |
| Active tab | 1 | `WebViewModel.activeTabId` |
| Parked tabs | N | `SiteTab` in prefs (~200 B each) + `webview_state/<siteId>.<tabId>.enc` (1 to 50 KB, only when the tab has history to keep) |

Invariants:

- Tabs never change the number of live webviews. `kMaxLoadedSites`,
  `kMaxResidentSites`, `SiteUnloadEngine` and
  `SiteLifecyclePromotionEngine` keep the site as their unit and do not
  learn about tabs. Evicting a site captures its active tab's bytes (as
  today, now keyed by tab) and leaves parked tabs untouched: there is nothing
  in memory to evict.
- `persistsNavState` (false for incognito and archive-tier) gates every write
  exactly as it does now, so those sites' parked tabs are records only.
- Disk is bounded by tab count. Closing a tab removes its file; deleting a
  site removes every `webview_state/<siteId>.*.enc`; the startup orphan sweep takes the
  set of live `<siteId>.<tabId>` keys.

### D3. A tab switch is capture, dispose, rebuild, restore

`TabLifecycleEngine.activate(site, targetTabId)` emits, in order:

1. `capture(activeTab)` when the site's webview is live (skipped when
   `persistsNavState` is false).
2. `park(activeTab)`.
3. `dispose()`.
4. `queueRestore(target)` when bytes exist for the target.
5. `bind(target)`: rebuild the webview. The `IndexedStack` child for the site
   keeps its `ValueKey(siteId)` slot (WEBSPACE-011) and wraps the webview in a
   `KeyedSubtree` keyed by `activeTabId`, so the framework remounts it. The
   existing `onControllerCreated` consumes the queued bytes: deferred initial
   load plus reload on Android, `interactionState` on Apple.

Steps 1 and 4 are the two halves of BUG-003's invariant, so the pairing holds
without a new path. Step 3 is the reason a switch never holds two webviews.

Cost: one renderer respawn per switch, the same as returning to an evicted
site or pressing Home. Accepted for this round; a warm second webview is the
named future tier if it turns out to matter.

### D4. New tab and open in new tab

- **Opening a site** (strip, drawer, cold start, shortcut, share arrival)
  SHALL resume the site's active tab and SHALL NOT create one.
- **New tab**: root tab at `initUrl`, becomes active; the previous active tab
  parks (D3). Reached from the Tabs sheet header and both overflow menus. The
  rebuild is the NAV-004 shape, so the new tab starts with an empty history.
- **Duplicate tab** (TAB-010): the active tab's record and back stack copied
  into a parked sibling. Reached from both overflow menus and a long press on
  either refresh button; opens in the background like "Open in new tab".
- **Open in new tab**: offered on a link's long-press menu only when the link
  is inside the site's domain. Creates a parked child tab (`parentId` = the
  current tab) and shows a snackbar with "Switch". No webview and no bytes
  are created until it is first activated. A cross-domain link's menu shows
  the row disabled with the reason; its tap keeps opening the nested screen.
  The long press comes from the plugin's `onLongPressHitTestResult`, which is
  Android and iOS only — there is no macOS or Linux signal for it — so on
  desktop a tab comes from "New tab" and the tree stays flat. A JS
  `contextmenu` shim would cover all four and is the obvious follow-up if
  desktop turns out to matter; it was not worth a new shim, its jsdom tests
  and its drift fixtures for this round.
- **Home** (NAV-004): the active tab goes to `initUrl` with history cleared.
  No new tab.

The prototype exposes "opening a site starts a new tab" as a knob so the
alternative can be felt; the proposal is resume.

### D5. Back at the start of a child tab

`TabLifecycleEngine.onBackAtHistoryStart(tab)`:

- child tab (has `parentId`) -> `close(tab)`, activate the parent.
- root tab -> no-op (NAV-001).

The prototype offers "park instead of close" and "do nothing" as knobs.
Proposed default: close, because a list that grows on every back is a list
nobody trusts.

### D6. The tree

- Order is creation order; the active tab is highlighted, never moved.
- A node with children shows a collapse chevron; collapsed state is UI-only.
- Row actions: switch, close, close tab and its children. Closing re-parents
  children to the closed tab's parent.
- Collapsing a tab hides its whole subtree, and the row says how many tabs
  that is — the direct-child count would under-report a chain.
- Surfaces: the Tabs sheet (app bar square with the site's tab count; tapping
  the active site's strip chip, which is a no-op today) with "New tab", "Close
  N parked" and, once more than one site is shown, an "All sites" scope. Strip
  chips and drawer tiles carry a count pill when a site has more than one tab,
  and nothing when it has one, so a user who never opens a second tab sees no
  new chrome. The drawer lays sites out as a grid of tiles, not rows, so the
  tree does not fit there; the "All sites" scope is the whole-app tree view.
- A locked kiosk shell (KIOSK-002) hides the sheet and the link menu.

### D7. Per-site feature audit for tabs

| Feature | Rule for tabs |
|---|---|
| Incognito (INC-002/003) | Tabs exist in memory only; no state bytes, `tabs` omitted from JSON. Relaunch keeps one home tab. |
| Always open Home (AOH-001) | Drops the tab list on serialise, exactly as it drops `currentUrl`: the site comes back with one tab at `initUrl`. Keeping parked tabs would write a banking-style site's deep URLs into plaintext preferences, which is the thing the toggle exists to avoid. One rule, not two. |
| Kiosk (KIOSK-002) | Locked shell hides the Tabs sheet, the drawer tree and the link menu. Back on a child tab still follows D5. |
| Archive tier (ARCH-001/006) | `tabs` ride the archive's encrypted state; no state bytes are written (`persistsNavState` false); app-tier prefs are byte-identical whether archives hold tabs or not. |
| Notifications / background audio | Only the active tab runs JS; a parked tab cannot fire a notification or play. Retention tiers unchanged. |
| Memory pressure / LRU cap | Unchanged: the unit is the site's one webview. A parked tab is never in memory. |
| Settings backup | `tabs` ride `WebViewModel.toJson`; state bytes do not (same as the HTML cache). |
| Site QR share | Never carries tabs (session, not configuration). |
| Site delete / `SiteTeardownEngine` | Removes every `webview_state/<siteId>.*.enc`. |
| Nested screen (NESTED-010) | Unchanged. It is opened from the active tab and is not a tab. |
| Legacy cookie engine (ISO-001) | Untouched: a tab switch never changes the site's domain, so no capture-nuke-restore runs. |
| Home shortcut (HS-006) | Resets the active tab, as it resets `currentUrl` today. |

## Risks / Trade-offs

- **A switch costs a renderer respawn.** Same cost as Home or as returning to
  an evicted site; the cheapest correct option on Android, where restore needs
  a pristine list. Measured, not assumed: the first implementation step
  instruments switch latency in `LogService` so the warm-webview tier is a
  decision made on numbers.
- **`currentUrl` as a getter** touches many call sites in `main.dart`. The
  compatibility getter keeps reads working; writes move to
  `activeTab.url = ...`, a mechanical change gated by the analyzer.
- **Lists grow.** Mitigated by the backwards-closes rule, "Close N parked",
  and the fact that opening a site never adds a tab. Sweeping is a later
  round.
- **Naming.** The bottom strip is the "site tab strip" and its chips are
  sites. The new objects are "tabs" of a site. Copy in the sheet always says
  whose tabs they are ("GitHub, 4 tabs").

## Open Questions (the prototype's knobs)

Both are settled in the code as proposed; they stay listed because the
prototype can still be used to feel the alternatives.

1. Back at the start of a child tab: close (implemented), park, or nothing?
2. Opening a site from the strip or drawer: resume its active tab
   (implemented) or start a new tab at home?

Deferred from this round, listed so they are not lost: a crumb under the app
bar naming the tab a child was opened from; a `contextmenu` shim so desktop
gets the long-press menu; a warm second webview per site.

## Migration Plan

1. `SiteTab` model on `WebViewModel`, JSON migration, `currentUrl` getter;
   state storage keyed by tab; orphan sweep per tab; switch-latency logging.
   No UI. Tests: model round-trip, migration, storage keys, audit rows for
   incognito and archive.
2. `TabLifecycleEngine` (activate / park / new tab / close-with-reparent /
   back-at-start / tree order) with in-memory fakes modelling the state store.
3. Tabs sheet, strip pill, "New tab", link long-press "Open in new tab",
   back-at-start rule. Ships the accumulation loop.
4. Drawer and strip counts, kiosk and archive gates.

Each step is independently shippable; the compatibility getter means step 1
alone changes nothing a user can see.
