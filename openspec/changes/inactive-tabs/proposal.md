## Why

WebSpace gives a site its own cookies and settings, but only one page. Open a
second page from GitHub and either the first one is gone (in-domain navigation
replaces `currentUrl`) or the second one is (a cross-domain hop lives in a
nested `InAppWebViewScreen` and dies on back). Nothing accumulates, which is
the one thing a browser does that this app does not, and the reason
save-for-later products fail: inactive tabs are the reading list, in place,
with the session that opened them.

The first draft of this change also folded in share arrivals, links that
another site claims, and cross-domain sub-pages. Those flows are harder and
are cut from this round. What remains is the part a browser cannot do without:
tabs inside a site, a tree to see them in, and a memory model that never
costs a second renderer.

## What Changes

- A site owns a list of **tabs**. A tab is a URL inside the site's own domain,
  a title, the tab it was opened from, and the site's saved navigation state
  for it. Exactly one tab per site is **active** and bound to the site's single
  resident webview; every other tab is **parked** and holds no renderer.
- **All tabs of a site share the site's container** (`ws-<siteId>`): cookies,
  localStorage, IndexedDB, ServiceWorkers, HTTP cache. Nothing is per tab on
  the native side.
- **Switching tabs inside a site is the existing `savedForRestore` walk, per
  tab**: capture the active tab's state, dispose the webview, rebuild it with
  the target's state queued. The number of live webviews never changes.
- **Opening a site never creates a tab**: it resumes the site's active tab.
  Only "New tab" creates a root tab (at `initUrl`, parking the current one),
  and only "Open in new tab" on an in-domain link creates a child tab (in the
  background, under the tab it came from).
- **System back at the start of a child tab closes it** and returns to its
  parent, as Chrome does. Root tabs keep NAV-001's no-op.
- The **tree**: a per-site Tabs sheet (app bar square with the count, tap on
  the active site's chip) and the same tree under each site in the drawer;
  collapse, close, close subtree; closing a tab re-parents its children.
- The per-site feature audit (ARCH-006 shape) for tabs: incognito tabs never
  reach disk, Always open Home reverts only the active tab, kiosk hides the
  tab UI, archive-tier tabs live under the archive key, the QR share never
  carries tabs, memory pressure and the LRU cap keep the site as their unit.

## Hosted tabs and reattach (specified, not implemented yet)

This change builds on outbound routing (`route-outbound-via-lir`, PR #345), which sends a link a site opens to the site that claims it. Once a site has tabs, the same routing can decide what a tab runs as:

- **Hosted tabs.** `SiteTab.hostSiteId`: a tab owned by site A (listed, closed and backed out of in A's tree) that runs as site B (B's container, cookies, and every per-site setting). No extra webview: activating it rebuilds A's one slot with B's identity, which is what a tab switch already does. Container engine only; neither side archive-tier; the host must own a persistent container, so not incognito.
- **Creating one.** Long-press a cross-domain link and "Open in new tab as {site}", where TAB-006 shows a disabled row; or "Keep as tab" on a nested screen, which turns the transient window into a child of the tab it came from. Plain taps stay as LIR-015 nests them.
- **State.** Navigation bytes are keyed by the host, so wiping or deleting the host takes them along, and moving a tab between owners needs no rename. The record persists only when both the owner and the host would persist their URLs.
- **Host gone.** Deleting, archiving or turning incognito on for a host closes the tabs it hosts, before its container is deleted. They do not fall back to the owner, which would silently switch identity.
- **Proxy.** The process-global proxy rules read the identity a slot runs as. This changes shared runtime state, so it goes through the formal mix gate (proxy, containers) before any code.
- **Reattach instruments** in the tab list: "Move to site..." moves a tab and its subtree to another site's tree, keeping each tab's identity and its state; "Move under..." re-parents within a site; "Run as..." changes a tab's host and drops its state, because restoring one identity's saved state (Apple `interactionState` holds typed form data) into another's container would carry it across. Each is a pure `TabLifecycleEngine` operation.

LIR-018 to LIR-027 land after the tab model above (`tasks.md`). TAB-001, TAB-002 and TAB-006 name their one exception each: a hosted tab's URL is in its host's domain, it shares its host's container and posture, and the disabled cross-domain row gains "as {site}" rows. The ids stay in the LIR range, since the requirements extend `link-intent-routing`.

## Out of scope this round

- Share-sheet and `webspace://` arrivals landing as tabs (they replace the
  site's page or open nested, exactly as today).
- Cross-domain pages as tabs, other than hosted tabs above: a cross-domain
  tap still opens the ephemeral nested screen, or routes to the site that
  claims it (`route-outbound-via-lir`). A tab that is not hosted is always in
  its site's domain, so the container question has one answer.
- Keep limits, pins, sweeping, and a bulk "close the rest". Closing a tab or
  a subtree from the list is the only hygiene.
- A warm second webview per site.

## Status

The tab model (TAB-001 to TAB-012) is implemented and experimental: it needs
developer mode and the Experimental group's Site tabs switch, which is off by
default (TAB-012, DEVTOOLS-011). Hosted tabs and reattach
(LIR-018 to LIR-027) are specified and not implemented; `tasks.md` tracks them.
The flow is also captured in a clickable prototype (a static HTML simulator of
the phone, the site strip, the drawer tree, the Tabs sheet, the link menu, a
memory panel with OS-pressure and relaunch buttons, and an engine log).

## Capabilities

### New Capabilities
- `inactive-tabs`: per-site tab list with one active tab and N parked tabs, a
  parent tree, the new-tab and open-in-new-tab mechanisms, the
  capture/dispose/rebuild switch, the back-at-start rule, the Tabs sheet and
  drawer tree.

### Modified Capabilities
- `developer-tools`: DEVTOOLS-011's Experimental group gains the Site tabs
  switch, off by default (TAB-012).
- `link-intent-routing`: hosted tabs and reattach, LIR-018 (owned by one site, runs as another), LIR-019 (who may host), LIR-020 (open in new tab as another site), LIR-021 (keep a nested screen as a tab), LIR-022 (persistence and host-keyed state), LIR-023 (host deleted, cleared, archived or ineligible), LIR-024 (the process-global proxy follows the running identity), LIR-025 (move to site), LIR-026 (move under), LIR-027 (run as).
- `webview-pause-lifecycle`: `WebViewStateStorage` is keyed by
  `<siteId>.<tabId>`; PAUSE-009 capture points write the active tab's bytes.
- `navigation`: NAV-004 Home acts on the active tab; NAV-001 gains the
  child-tab close rule.
- `lazy-webview-loading`: the `IndexedStack` child for a site is additionally
  keyed by its active tab so a switch remounts the webview.
- `always-open-home`, `incognito-mode`, `kiosk-mode`, `archive`,
  `site-settings-qr`, `settings-backup`: one scenario each for what a tab does
  under that feature (see the audit table in `design.md`).

## Impact

- `WebViewModel`: `tabs`, `activeTabId`; `currentUrl`/`pageTitle` become the
  active tab's fields (getter-compatible, JSON migration synthesises one tab
  from a legacy `currentUrl`).
- New pure-Dart engine `lib/services/tab_lifecycle_engine.dart` (activate,
  park, new tab, close-with-reparent, back-at-start, tree order).
- `SecureWebViewStateStorage` keyed by `<siteId>.<tabId>`; orphan sweep per
  tab; site delete removes the site's directory.
- UI: count pill on strip chips and drawer tiles, Tabs sheet, drawer tree
  rows, link long-press menu, "New tab" in the overflow.
- Kernel model: the `loaded` set and `Inv_CurrentLoaded` are unchanged (one
  webview per site). The tab list is state beside it, not inside it.
- Hosted tabs: `SiteTab.hostSiteId`; the running-identity view in `WebViewModel.getWebView`; host-keyed state keys and `WebViewStateStorage.renameState`; `TabLifecycleEngine.moveSubtree`, `reparent`, `changeHost`; `identityOf` in `SiteUnloadEngine`; the long-press rows, `InAppWebViewScreen.onKeepAsTab`, and the tab-list actions.
- **Formal**: the mix gate for hosted tabs against `formal/proxy.tla` and `formal/containers.tla` (and `formal/kernel.tla` if the tab switch is modelled there), before implementation.
