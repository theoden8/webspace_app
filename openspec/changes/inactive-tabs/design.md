## Context

What exists today, in the terms this design has to fit:

- A **site** (`WebViewModel`) is one identity: a container `ws-<siteId>` (or
  the legacy shared jar), per-site settings, and one `currentUrl`/`pageTitle`.
  One `InAppWebView` per site, created lazily (`lazy-webview-loading`
  LAZY-002), kept resident across site switches (LAZY-004), capped at
  `kMaxLoadedSites` (20) with a resident comfort limit of `kMaxResidentSites`
  (10) beyond which `SiteLifecyclePromotionEngine` walks a site
  `resident -> cacheCleared -> savedForRestore`.
- `savedForRestore` already is an inactive tab in everything but name: the
  webview is disposed, `controller.saveState()` bytes sit AES-encrypted in
  `<docs>/webview_state/<siteId>.enc` (`SecureWebViewStateStorage`), and the
  next activation rebuilds the webview and calls `restoreState`. The capture
  points are PAUSE-009 (go-home, app-background, navigation with a 3 s trailing
  debounce) and the pairing rule is BUG-003's invariant: every path that keeps a
  webview across a restart pairs a capture before death with a restore queue
  before first build.
- A **cross-domain hop** with a gesture opens a nested `InAppWebViewScreen`
  (NESTED-004) that shares the site's container and carries its whole posture
  (NESTED-010). It has no `WebViewModel`, persists nothing, and pops when its
  own history runs out (`inappbrowser.dart` PopScope) or when the app bar back
  arrow is tapped. Closing the app kills it.
- **Link-intent routing** resolves an inbound URL to a site (LIR-002) and then
  `LinkIntentDispatchEngine` emits `DispatchOpenInMain` (replace the site's
  page, with LIR-011's reset flags for incognito / always-home sites) or
  `DispatchOpenNested` (out-of-domain: nested screen). The LIR-010 picker
  offers "open in <site>", "add the domain to a site" (opt-in claim, default
  off per discussion #439) and "create site". Nothing it does survives the
  next navigation.
- The user model on screen: the drawer grid and the bottom tab strip list
  **sites**, one chip each (WEBSPACE-011 reorder). There is no place a second
  page of a site could appear.

So the app has a per-site *memory* tier that looks exactly like a discarded
tab, and a per-site *routing* brain that knows which site a URL belongs to,
and neither has a list to put a page in. That list is the whole feature.

## Derivation

Start from the browser feature and apply the app's constraints one at a time.

1. **A tab must belong to a container.** In a browser a tab is a global
   object. Here every page renders inside one site's container and posture,
   so a page belongs to a site. The site is the tab group. This is the Firefox
   Multi-Account Containers shape: a container has tabs; a tab is in exactly
   one container.
2. **One resident webview per site stays.** N live webviews per site would
   multiply renderer processes under a cap that is already tuned per site,
   would re-open the same-base-domain conflicts the legacy engine serialises
   (ISO-001), and would need a second copy of every lifecycle engine. Instead
   a site's pages share its one webview: exactly one page is **active** and
   bound to it; the rest are **parked**, which is `savedForRestore` keyed by
   page. Mobile browsers discard background tabs anyway; the honest name for
   an inactive tab is "url, title, and a state blob".
3. **Switching pages within a site is the existing tier walk.** Activate P2
   while P1 is active: `saveState(P1) -> store[site/P1]`, then `loadUrl(P2)` or
   `restoreState(store[site/P2])` in the same webview. Switching *sites* does
   not touch pages: each site keeps its own active page, exactly as today.
4. **What survives is decided by direction.** Two exits from a page exist:
   - *sideways*: the user switches to another page or site, opens a link in
     the background, shares a URL in, backgrounds the app. The page parks.
   - *backwards*: the system back gesture at the start of a child page's
     history. The page closes and its parent takes over. This is exactly what
     the nested screen does today when its history runs out, and it is
     Chrome's rule for a tab opened from another tab. Root pages at history
     start stay a no-op (NAV-001).
   A page you never scrolled and backed out of leaves no residue; a page you
   left to do something else waits for you. That rule is the whole answer to
   "why did this tab appear" and "where did my tab go".
5. **Accumulation paths fall out of the exits.**
   - Long-press a link, "Open in new page": a parked child of the current
     page (the browser's open-in-background).
   - "Park this page" from the overflow (or "New page at home"): the page you
     are on parks, and its parent or the site home takes the webview.
   - A shared URL resolves to a site and lands parked in its list, with a
     snackbar to open it. The share no longer replaces the page the site was
     on, which also removes the reason LIR-011 had to dispose and wipe a live
     webview: a parked page touches no webview at all.
   - A cross-domain hop kept by switching away instead of backing out.
6. **The tree is free.** Every path above knows the page it started from, so a
   page records `parentId`. The drawer already lists sites; expanding a site
   shows its pages indented by depth, which is tree-style tabs without a new
   surface. Closing a parent re-parents its children to the grandparent, as
   Tree Style Tab does, so nothing is orphaned by a close.
7. **The routing brain gets a second verb.** LIR already answers "which site
   does this URL belong to". With a list to put a page in, the dispatcher can
   *add* as well as *open*. And the same resolver can answer an in-app tap: a
   GitHub link tapped on Mastodon today opens nested inside Mastodon's
   container, without GitHub's login. With the picker it can open in GitHub,
   or be added to GitHub for later, or open here as before.
8. **Hygiene is a per-site knob, not a global inbox.** Safari's "close tabs
   after a day / week / month" and Chrome's 21-day archive both exist because
   lists grow. A per-site keep limit on the Behaviour screen, pinned pages
   exempt, swept at launch. Default "until closed" so the list is trusted.

## Goals / Non-Goals

**Goals**

- A site accumulates pages without losing the one it is on.
- A page survives sideways exits and app restarts; a backed-out child page
  does not.
- One resident webview per site, unchanged eviction and memory-pressure rules.
- Reuse: `SecureWebViewStateStorage`, `SiteLifecyclePromotionEngine`,
  `LinkIntentDispatchEngine`, the `_DispatchPickerSheet`, the nested screen.
- Every per-site feature that touches `currentUrl` or on-disk state gets an
  explicit answer for pages (audit table below).

**Non-Goals**

- Multiple live webviews per site (a warm second page). Could be a later tier.
- Cross-site trees: a page opened from another site's page is a root in its
  own site with an `origin` note, never a child across containers.
- A global "all tabs" screen as the primary surface. The drawer tree and the
  per-site sheet with an "All sites" scope cover it.
- Changing what the legacy cookie engine serialises (ISO-001).
- Sync or cloud anything.

## Decisions

### D1. Page model on the site

```dart
class SitePage {
  final String id;          // path-safe token, same pattern as siteId
  String url;
  String? title;
  String? parentId;         // page it was opened from, same site only
  DateTime createdAt;
  DateTime lastActiveAt;
  bool pinned;
}
// WebViewModel
List<SitePage> pages;       // display order = tree order
String activePageId;
String get currentUrl => activePage.url;   // compatibility getter
```

`currentUrl` and `pageTitle` stay as getters over the active page so the
existing persistence, always-home and incognito code keeps reading the same
names. Migration: JSON without `pages` synthesises one root page from
`currentUrl` (or `initUrl`) and makes it active; serialisation omits `pages`
while it holds exactly that synthesised page, so on-disk output is stable for
users who never open a second page (same rule as LIR-001's `domainClaims`).

Alternative: global `Tab` objects with a `siteId`. Rejected: every consumer of
"the site's page" would have to look up the tab, and the archive tier's
byte-identity rule (ARCH-001) is far easier to hold when pages ride the site's
own serialisation.

### D2. One active page, parked pages are state blobs

Invariant, per site: `pages.where(active).length == 1` and only the active
page can have a controller. `SecureWebViewStateStorage` is keyed by
`<siteId>/<pageId>` (`webview_state/<siteId>/<pageId>.enc`). The
`removeOrphans` sweep takes the set of live page keys. `persistsNavState`
(false for incognito and archive-tier) gates the write exactly as it does now.

Switching pages inside a site is a `PageLifecycleEngine.activate` that emits
`[capture(prev), bind(next, restore: hasState)]`; the call site runs the
capture through the existing `_captureStateBytes` path and the bind through the
existing `schedulePendingRestoreState -> onControllerCreated -> restoreState`
queue, so BUG-003's pairing invariant holds without a new path.

### D3. Sideways parks, backwards closes

`PageLifecycleEngine.onBackAtHistoryStart(page)`:

- child page (has `parentId`) -> `close(page)`, activate parent.
- page opened from another site (`origin`) -> `close(page)`, switch to the
  origin site and its page.
- root page -> no-op (NAV-001).

The nested `InAppWebViewScreen` remains the viewer for a child page whose
origin is outside the site's domain (a "foreign" page): it already implements
the pop-at-history-start rule and carries the posture (NESTED-010). What
changes is that the screen is now backed by a `SitePage`, so a sideways exit
from it (tabs button, app background) parks it instead of losing it, and its
URL/title reach persistence.

Open knob: "park instead of close on back" (the prototype's first policy).
Default close, because a list that grows on every back is a list nobody
trusts.

### D4. Accumulation via the dispatcher, not new call sites

`LinkIntentDispatchEngine` gains:

- `DispatchOpenInMain.activate: false` (parked root page in the site, no
  webview touched, no LIR-011 reset needed).
- picker rows `Add to <site>` for each winner and for the secondary site list;
  the existing `sendToSite(claimDomain:)` rule decides whether a claim is
  recorded, unchanged.
- an in-app entry point: `NavigationDecisionEngine` already returns
  `blockOpenNested` for a gesture cross-domain tap; when the target resolves
  to another site (`LinkRoutingService.resolve` single winner that is not this
  site) the call site shows the same picker with "Open in <site>", "Add to
  <site>", "Open here". `blockSilent` and `blockSuppressed` are untouched, so
  a gesture-less redirect never reaches the picker.

The long-press menu on a link calls the same engine entry points with
`activate: false`. No new decision logic lives in the view.

### D5. Surfaces

- **Tab strip chip / drawer tile**: count pill when a site has more than one
  page. Tapping the *active* site's chip opens the Pages sheet (today it is a
  no-op).
- **App bar**: the browser's square-with-a-number opens the Pages sheet.
- **Pages sheet**: scope "This site / All sites"; tree rows (favicon, title,
  host, age, pin, close); "New page at home"; "Close N parked".
- **Drawer**: each site row expands to its tree. This is the tree-style-tabs
  view and needs no new screen.
- **Crumb** under the app bar on a child page: "opened from <parent>"; on a
  foreign page: "foreign page in <site>'s container" (the nested screen's
  identity today, made visible).

### D6. Hygiene

`keepParkedPages: never | 1d | 7d | 30d` per site on the Behaviour screen
(BEHAV-001 "Opening and display" group). Swept at launch and on foreground
resume by `PageLifecycleEngine.sweep(now)`: parked, unpinned, `lastActiveAt`
older than the limit. Default `never`.

### D7. Per-site feature audit for pages

| Feature | Rule for pages |
|---|---|
| Incognito (INC-002/003) | Pages exist in memory only; no state bytes, `pages` omitted from JSON. Relaunch drops every parked page and reverts the active one to home. |
| Always open Home (AOH-001) | Only the *active* page reverts to home on cold start and shortcut tap; parked pages persist. The reverted page parks so nothing is lost. |
| Kiosk (KIOSK-002) | Locked shell hides the Pages sheet, the drawer tree and the link menu. A child page still opens and closes by the back rule. |
| Archive tier (ARCH-001/006) | `pages` ride the archive's encrypted state; state bytes are never written (`persistsNavState` false); app-tier prefs are byte-identical whether archives hold pages or not. |
| Notifications / background audio | Only the active page runs JS; parked pages cannot fire notifications. The retention tier is unchanged. |
| Memory pressure / LRU cap | Unchanged: the unit is still the site's one webview. Parking is cheaper than eviction, never dearer. |
| Settings backup | `pages` ride `WebViewModel.toJson`; state bytes do not (same as the HTML cache). |
| Site QR share | Never carries pages (they are session, not configuration). |
| Site delete / `SiteTeardownEngine` | Removes every `<siteId>/*.enc` state file. |
| Nested screen posture (NESTED-010) | Unchanged; the screen now also reports url/title to its `SitePage`. |
| Legacy cookie engine (ISO-001) | Untouched: page switches inside one site never change the site's domain, so no capture-nuke-restore runs. |

## Risks / Trade-offs

- **Lists grow.** Mitigated by the backwards-closes rule, the keep limit and
  the "Close N parked" action. The share default ("add to list") is the one
  path that adds without the user looking; the snackbar's "Open" keeps it
  visible.
- **State blobs per page multiply disk use.** Bounded: one blob per parked
  page, tens of KB each, swept with the page. Incognito and archive write none.
- **Two viewers for a page** (main webview for in-domain pages, nested screen
  for foreign pages). Accepted for v1 because the nested screen already has the
  posture threading and the pop rule; collapsing to one viewer is a later
  refactor that can happen behind the same `SitePage` model.
- **`currentUrl` as a getter** touches many call sites in `main.dart`. The
  compatibility getter keeps reads working; writes (`currentUrl = ...`) move to
  `activePage.url = ...`, which is a mechanical change gated by the analyzer.

## Open Questions (the prototype's knobs)

1. Back at the start of a child page: close (proposed) or park?
2. A shared URL that resolves to one site: add to its list (proposed) or open
   now (today's behaviour)?
3. An in-app tap on a link another site claims: ask (proposed), always route to
   that site, or always open here (today)?
4. Keep-limit default: until closed (proposed) or one month?
5. Should the crumb on a child page be tappable (returns to the parent, parking
   the child) or informational only?

## Migration Plan

1. `SitePage` model on `WebViewModel`, JSON migration, `currentUrl` getter;
   state storage keyed by page; orphan sweep per page. No UI. Tests: model
   round-trip, migration, storage keys, audit rows for incognito and archive.
2. `PageLifecycleEngine` (activate / park / close-with-reparent /
   back-at-start / sweep) with in-memory fakes modelling the state store.
3. Pages sheet, tab-strip pill, "New page at home", "Park this page", link
   long-press "Open in new page". Ships the in-site accumulation loop.
4. Share arrival: `activate: false` path in the dispatcher and the picker's
   "Add to <site>" rows.
5. Nested screen backed by a `SitePage`; sideways exits from it park.
6. In-app cross-site picker on `blockOpenNested`.
7. Drawer tree, keep limit on the Behaviour screen, kiosk and archive gates.

Each step is independently shippable; the compatibility getter means step 1
alone changes nothing a user can see.
