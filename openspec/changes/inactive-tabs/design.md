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
- Next in this change: a tab in one site's tree can run as another site, and
  tabs and subtrees can be moved between sites, re-parented, and switched to
  another identity (hosted tabs, D8 to D16).

**Non-Goals (this round)**

- Share arrivals and `webspace://` opens as tabs.
- In-app taps on links another site claims: outbound routing
  (`route-outbound-via-lir`, which this change builds on) handles them, and
  the link menu's Open routes the way a tap does.
- Cross-domain tabs other than hosted tabs, and a nested screen backed by a
  tab.
- A second webview per site for hosted tabs, carrying a nested screen's state
  into a kept tab, or keeping state across a host change.
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

## Hosted tabs and reattach (LIR-018 to LIR-027)

Specified here, implemented after the tab model (`tasks.md`). They build on outbound routing (`route-outbound-via-lir`, LIR-013 to LIR-017), which this change sits on, and on the tab model above, in the terms its code uses: a site owns `List<SiteTab> tabs` (`id`, `url`, `title`, `parentId`, `createdAt`, `lastActiveAt`) forming a tree; `activeTabId` names the tab bound to the site's one webview; `_switchActiveTab` is TAB-003's capture, dispose, queue, rebuild; `webViewStateKey(siteId, tabId)` is `<siteId>.<tabId>` `removeStatesForSite(siteId)` sweeps the `<siteId>.` prefix at site delete, data wipe and archive close; `TabLifecycleEngine` is pure. The tab model leaves cross-domain tabs out ("a tab is always in its site's domain, so the container question has one answer"). A hosted tab gives the container question a second answer, on purpose, per tab.

### D8. Owner and host

`SiteTab.hostSiteId`, `null` meaning the owner, normalised so a value equal to the owner is stored as `null`. The **running identity** of a slot is `hostOf(activeTab) ?? owner`. The owner keeps everything that is about the slot; the host supplies everything that is about who the page is:

| From the host (identity) | From the owner (slot) |
|---|---|
| container id, as the host's own webview binds it | the `IndexedStack` slot and its `ValueKey(siteId)`; loaded-set membership |
| every POSTURE field of `test/js/nested_webview_posture_parity.test.js`, through the host's `effective*` getters | per-instance and global pause, retention tier, notification auto-load, background-audio exemption |
| `cookieSiteId`, the model `onCookiesChanged` writes, the `blockedCookies` sweep | kiosk and fullscreen shell, back-forward gestures |
| the fingerprint seed (`siteId` plus `fingerprintResetNonce`) | the tab list, the tab's url and title writes, back-at-start (TAB-007) |
| same-domain test (`initUrl`, claims), `blockAutoRedirects`, `externalLinksInBrowser`, outbound routing source | device-access badges: the slot holds the live capture, and MIC-014 ends it on the slot's deactivation |
| block-statistics and notification attribution; camera, microphone and location decisions from the host's stored modes | the HTML cache: off while a hosted tab is active |
| Home (NAV-004) target: the host's `initUrl` | |

The cookie mirror row is the easy one to get wrong. `getWebView` today does `cookies = newCookies; await saveFunc();` on `this`. Under a hosted tab, `this` is the owner, so a naive rebuild would write GitHub's session cookies into DuckDuckGo's cookie secure storage. The identity view (D9) makes it the host's model.

The HTML cache is per site and paints the owner's own page on a cold first frame; a hosted page written there would flash on the owner's next start, and a host's page read from there would not be the host's. A tab switch already evicts the cache; hosted tabs simply never touch it.

Any path that loads an owner URL into the owner's slot (home shortcut, the Always open Home reset, LIR-011 `DispatchOpenInMain`) first binds a tab the owner runs itself: the active tab if it has no host, else its nearest such ancestor, else a new root at `initUrl`. Loading `duckduckgo.com` into a slot bound to GitHub's container would put DuckDuckGo's page in GitHub's cookie jar.

### D9. Reading the host inside `getWebView`

`WebViewModel.getWebView` reads `this.<field>` for every posture field, in the `WebViewConfig(...)` call and in the two `launchUrlFunc(...)` call sites. The change introduces an identity view: `getWebView` takes the running identity (the host's model, or `this`) and every POSTURE, identity-plumbing and navigation-rule read goes through it, while slot plumbing keeps reading `this`. A structural gate extends the posture parity test: in `getWebView`, every POSTURE field of the main-slot `WebViewConfig(...)` and of both `launchUrlFunc(...)` calls is read from the identity, never from `this`.

**Alternative considered**: render a hosted tab with the nested screen's config path, which already takes a whole posture as parameters. Rejected: the nested surface has none of the main slot's restore queue, deferred initial load, pause lifecycle, renderer-gone recovery via `_loadedIndices`, or find-in-page, and a tab has to behave like a tab. The cost is a wide mechanical edit in `getWebView`, listed in Open Question 5.

### D10. Who may host

- **Container engine only.** On the legacy engine a slot cannot switch cookie identity without capture-nuke-restore, which is keyed by site, not by tab.
- **App tier only, both sides.** An archive-tier owner hosting an app-tier site would run archive browsing in an app-tier container; an app-tier record naming an archive host would break ARCH-001.
- **The host is not effectively incognito.** This is a deviation from the brief, which allowed an incognito host with no state file. On iOS, macOS and Linux an incognito site binds no named container (`siteOwnsContainerProfile` returns false; the fork uses an ephemeral store), so every rebuild of the owner's slot would get a fresh ephemeral store: neither the host's live session nor a persistent one, just its posture. That is not "runs as B". Android binds the named profile even under incognito, but a rule that holds on one platform only is a rule nobody can predict. Archive-tier sites are effectively incognito, so they are excluded on every platform, which also closes the archive boundary from the host side.
- **The URL is inside the host's navigation domain.** The host's own webview treats anything else as cross-domain, and `onUrlChanged` would navigate the restored tab straight back to `initUrl`. LIR claims rank candidates but do not make one: a Codeberg site claiming `codeberg.page` routes a `codeberg.page` tap but cannot hold a `codeberg.page` tab.

`hostCandidates(url, owner)` = eligible sites whose navigation domain equals the URL's, minus the current running identity, ordered by the owner's outbound preferences, then claim score, then site order.

### D11. Creating a hosted tab

- **Long-press** "Open in new tab as {site}", one row per candidate, replacing TAB-006's disabled row. Not gated by `routeOutboundLinks`: the row names the site, so the user is choosing, not being routed. A parked child, like TAB-006's.
- **Keep as tab** on a nested screen opened from a site's tab, including an LIR-015 routed one. The host is the screen's bound site when it may host the current URL, else a candidate the user picks ("Keep as tab as GitHub" on a DuckDuckGo-posture screen showing `github.com`). The screen pops and the new child becomes active. Nothing from the nested webview's state is carried. Even when the screen ran in the host's own container, capturing from a webview that is not a slot would be a new capture path outside BUG-003's pairing rule, and when it ran in the source's container its state belongs to the wrong identity. The page reloads fresh; a same-container capture is a possible follow-up (Open Question 6).
- **Plain taps** keep LIR-015. A tab is something the user asks for.

`InAppWebViewScreen` takes an optional `onKeepAsTab` callback, null for inbound-opened screens and under a locked kiosk shell, the same shape as passing no long-press handler to the nested screen.

### D12. Persistence and the state key

**Keys are host-keyed**: `webViewStateKey(hostSiteId ?? ownerSiteId, tabId)`. The brief proposed owner keys plus a `renameState` on every cross-owner move. Host keys are chosen instead, for three reasons:

1. `removeStatesForSite(B)` already runs at B's delete, B's data wipe (ETP-022) and archive close. With owner keys, wiping B would leave bytes produced as B (Apple `interactionState` holds typed form contents) on disk under A's prefix. Every such path would need its own "and also the hosted tabs" loop, and the next path to forget it is the "second entry point that skips the gate the first one has" shape `docs/security/README.md` lists among the recurring ones.
2. A move between owners with the host unchanged needs no rename.
3. The `persistsNavState` gate and the key prefix then name the same site.

The cost moves to the owner: deleting A no longer sweeps its hosted tabs' bytes by prefix, so the delete drops them explicitly (the engine returns the keys) and the startup orphan sweep, whose live set uses the same key function, is the backstop. `renameState(oldKey, newKey)` is still needed, but only when a moved tab's id collides in the destination tree, which is always the case for `kPrimaryTabId` (`main`), since every site's first tab has that id.

**Record persistence** = the owner persists tabs (TAB-009: neither `incognito` nor `alwaysOpenHome`) and the host would persist its own URL (neither of the two either). Otherwise the tab lives for the session only. A host with Always open Home keeps its deep URLs off disk even inside another site's tree. **Bytes** are written only for a persisted record whose running identity has `persistsNavState`, so no file ever exists for a record that is never written.

Backup carries `hostSiteId` inside the tab record; state bytes and the QR share never carry tabs (TAB-009).

### D13. When the host goes away

On host delete, move into an archive, or loss of eligibility (incognito turned on), the tabs it hosts close with TAB-007 re-parenting, and an owner whose active tab closed is re-bound first. The order matters for delete: `ContainerIsolationEngine.onSiteDeleted` requires the caller to have disposed every webview on the container, since `deleteContainer` is a no-op on iOS and macOS while the store is bound, and a surviving store would keep the deleted site's login.

**Close rather than fall back to the owner.** The brief left this open. Falling back would run the tab's URL as the owner: a signed-in GitHub page silently reloaded as DuckDuckGo, signed out, and usually outside DuckDuckGo's navigation domain, which LIR-018 forbids anyway. For two sites on the same domain (work and personal GitHub), where a fallback would be legal, it would be the identity switch the feature exists to make explicit. The user can re-create the tab with "Open in new tab as" or "Keep as tab".

Clear site data for B disposes every webview on B's container, including owner slots whose active tab B hosts, before `clearForSite(B)`; otherwise the live page there can write identifiers straight back after the wipe, which is what ETP-022's dispose-and-rebuild prevents. `removeStatesForSite(B)` then drops every B-keyed byte (D12).

GC at startup, import and delete closes tabs whose `hostSiteId` names no eligible host, with the same re-parenting.

### D14. Proxy and Tor follow the running identity

`SiteUnloadEngine.indicesToUnloadForProxyMismatch`, `indicesToUnloadForTorExitMismatch` and `torExitNodesFor` read `models[i]` today. They gain an `identityOf(int index)` parameter (default `models[i]`), and `_WebSpacePageState` passes the running identity. Router mode's `sharesDefaultSession` reads the identity's `_ownsContainerProfile`.

A rebind of the visible slot to a tab whose identity's proxy differs from the applied one is an activation for PROXY-008 purposes: unload the mismatched slots, apply, fail closed with no rebuild. A rebind of a background slot (the "All sites" scope of the tab list can close or move another site's active tab) never applies a proxy, because that would repoint the visible site. So when its identity mismatches, the slot is left disposed and out of `_loadedIndices` until its next activation, which is proxy.tla's existing "background load refuses a mismatched site" rule applied to a rebind.

**Formal obligation (mix gate).** This mutates shared runtime state: which proxy a loaded slot needs is no longer a per-site constant. Per CLAUDE.md "Formal verification", before implementation:

- `formal/proxy.tla`: make a loaded slot's required proxy `proxyOf[identity[s]]` with `identity` a variable; add `Rebind(s, i)` for the visible slot and for a background slot, and `OpenNestedAs(i)` / `PopNested` for LIR-015's routed screen and `route-outbound-via-lir` D6's return path; keep `Inv_EgressMatchesConfig` and `Inv_ProxyCoherent` (off-mode) over the identity. Negative demonstrator: a background rebind to a mismatched identity without unloading. Positive witness: a slot running a hosted identity co-loaded with the host's own slot.
- `formal/containers.tla`: add a slot-to-identity map; keep `Inv_Disjoint` over identities and add `Inv_PostureMatchesContainer` (a slot's container is its identity's container, and so is its cookie mirror). Negative demonstrator: a rebind that binds the host's container but mirrors cookies to the owner (the D8 cookie-mirror bug).
- `formal/kernel.tla`: no new variable. If the tab switch is modelled as a surface attach, enable it for hosted targets and re-check `RepaintLiveness` and `Inv_CurrentLoaded`.
- Re-run `./formal/check.sh`; `formal/proofs/proxy_coherent.tla` and `containers_disjoint.tla` need their invariants restated for `proofs/check_proofs.sh`.

### D15. Reattach instruments

Three row actions in the tab list, each one pure engine operation plus IO at the call site:

```dart
class TabMovePlan {
  final List<SiteTab> fromTabs;          // owner A after the move
  final String? fromNextActiveId;        // null: seed a home tab
  final bool fromRebind;                 // A's active tab left
  final List<SiteTab> toTabs;            // owner C after the move
  final Map<String, String> renameKeys;  // id collisions (kPrimaryTabId)
  final Set<String> dropKeys;            // C does not persist the record
  final TabMoveRefusal? refusal;
}

TabMovePlan moveSubtree({required TabOwnerView from, required String tabId,
    required TabOwnerView to, String? underTabId,
    required bool Function(String hostId, TabOwnerView owner) mayHost});
List<SiteTab> reparent(List<SiteTab> tabs, String tabId, String? newParentId);
({List<SiteTab> tabs, String? dropKey}) changeHost(TabOwnerView owner,
    String tabId, String? newHostId);
```

`TabOwnerView` is `{siteId, tabs, activeTabId, persistsTabs}`; `mayHost` wraps LIR-019 so the engine never sees archive or incognito flags.

- **Move to site...** (`moveSubtree`): the tab and its subtree move; each keeps its identity, re-normalised against the destination. If A's active tab moves, the call site captures it first (bytes travel with it), then applies the plan: rename, drop, then `_switchActiveTab` for A with `captureOutgoing: false` since the capture already ran. Moved tabs arrive parked; a snackbar offers "Switch". Refusals: legacy engine, archive-tier owner, a resulting host that may not host, a parent that is not in C.
- **Move under...** (`reparent`): within a site, both engines. Refuses a parent inside the moved subtree; moves the subtree to follow the new parent's last descendant, like `insertChild`; no state, no rebind.
- **Run as...** (`changeHost`): candidates are `hostCandidates` plus the owner when its domain allows. Drops the old key's bytes (D16). An active tab is re-bound with no restore queued, under D14.

UI: a row overflow menu in the tab sheet. "Move to site..." opens a site list (eligible owners), then that site's tree with a "Top level" row. "Move under..." opens the same site's tree with the moved subtree greyed. "Run as..." lists candidates with the current identity checked. A locked kiosk shell hides all three with the rest of the tab UI (KIOSK-002). The picker rows name sites and tabs, so strings are few: action labels, "Top level", refusal reasons.

### D16. Changing the host drops state

A saved state is a transcript of one identity's browsing: the back-forward list, scroll positions, and on iOS and macOS the `interactionState` blob that holds form field contents. Restoring it into another container would replay one identity's history and typed input as another, the cross-container leak containers exist to prevent. A host change therefore keeps only the URL and title and loads fresh. Owner moves keep the bytes because the identity does not change (D12).

### Per-site feature audit for hosted tabs

| Feature | Rule |
|---|---|
| Incognito owner | May own hosted tabs; records are session-only (TAB-009). |
| Incognito host | Cannot host (D10). Turning incognito on closes its hosted tabs (D13). |
| Always open Home owner | Tab list not persisted (TAB-009), hosted tabs included. Its reset binds an own tab first (D8). |
| Always open Home host | May host; its hosted tabs are session-only (D12). |
| Archive tier (ARCH-001/006) | Neither owns nor hosts. A move into an archive closes the relationships first. No new per-`siteId` residue. |
| Kiosk (KIOSK-002) | Locked shell hides the tab UI, the link menu and Keep as tab. |
| Notifications, background audio | Attribution follows the host; slot exemptions follow the owner. A parked tab runs no JS. |
| Memory pressure, LRU cap | Unchanged: the unit is the owner's slot. |
| Proxy, Tor | Follow the running identity (D14). |
| Settings backup | `hostSiteId` rides the tab record; no bytes. Import GC closes dangling hosts. |
| Site QR share | Never carries tabs. |
| Site delete, data wipe | Host side: close hosted tabs, dispose, then delete or clear (D13). Owner side: drop hosted tabs' bytes explicitly (D12). |
| Nested screen from a hosted tab | Opened with the host's posture; outbound routing uses the host as source. |
| Legacy cookie engine | No hosted tabs, no Move to site, no Run as. Move under works. |
| Home shortcut | Binds an own tab before loading the owner's home (D8). |

## Risks / Trade-offs

- **A switch costs a renderer respawn.** Same cost as Home or as returning to
  an evicted site; the cheapest correct option on Android, where restore needs
  a pristine list. Measured, not assumed: the first implementation step
  instruments switch latency in `LogService` so the warm-webview tier is a
  decision made on numbers.
- **`currentUrl` as a getter** touches many call sites in `main.dart`. The
  compatibility getter keeps reads working; writes move to
  `activeTab.url = ...`, a mechanical change gated by the analyzer.
- **Lists grow.** Mitigated by the backwards-closes rule, closing a subtree
  from the list, and the fact that opening a site never adds a tab. There is
  no bulk "close the rest": it reads as a nudge to throw tabs away. Sweeping
  is a later round.
- **Naming.** The bottom strip is the "site tab strip" and its chips are
  sites. The new objects are "tabs" of a site. Copy in the sheet always says
  whose tabs they are ("GitHub, 4 tabs").
- **[Risk] A hosted tab reads a field from the owner.** A single `this.<field>` left in `getWebView` runs the host's page with the owner's setting, or writes the host's cookies into the owner's store. Mitigation: the identity-read gate (D9) and the containers.tla demonstrator (D14).
- **[Trade-off] Keep as tab and Run as reload the page.** Both start the tab with an empty history. Accepted: the alternatives carry one identity's state into another, or add a capture path outside BUG-003's pairing.
- **[Trade-off] Closing hosted tabs when their host goes.** A user who deletes Work GitHub loses the tabs other sites opened as it. Accepted over a silent identity switch (D13).

## Open Questions (the prototype's knobs)

Both are settled in the code as proposed; they stay listed because the
prototype can still be used to feel the alternatives.

1. Back at the start of a child tab: close (implemented), park, or nothing?
2. Opening a site from the strip or drawer: resume its active tab
   (implemented) or start a new tab at home?

Deferred from this round, listed so they are not lost: a crumb under the app
bar naming the tab a child was opened from; a `contextmenu` shim so desktop
gets the long-press menu; a warm second webview per site.

Hosted tabs and reattach:

3. The identity view (D9) touches every posture read in `getWebView`. Is that edit acceptable in one step, or should it land first as a no-op refactor (identity is always `this`) ahead of hosted tabs?
4. Keep as tab loads fresh. When the nested screen already ran in the host's container (an LIR-015 routed screen), its `saveState` bytes belong to the right identity and could seed the new tab. Worth a second capture path, with its own BUG-003 pairing test?
5. The incognito-host exclusion (D10) is stricter than Android needs. Accept one cross-platform rule, or allow incognito hosts on Android only?
6. Should "Open in new tab as" also require `routeOutboundLinks`? The proposal says no, since the row names the site.
7. Incognito sites rebuild the webview on every tab switch, so on iOS, macOS and Linux each switch gets a fresh ephemeral store and the incognito session does not survive between the site's own tabs. Hosted tabs inherit whichever answer the tab model picks.

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

Hosted tabs and reattach follow the tab model, after the mix gate (D14) passes:

5. `SiteTab.hostSiteId`, normalisation, host-keyed state keys, `renameState`, persistence rules, GC.
6. The identity view in `getWebView` and its gate (D9); `identityOf` in the unload engines (D14); own-tab binding before owner loads (D8).
7. Long-press rows and Keep as tab.
8. `moveSubtree`, `reparent`, `changeHost` and the tab-list actions.
9. Host lifecycle on delete, clear, archive move and incognito.

Steps 5 and 6 change nothing a user can see: no tab has a host until step 7.
