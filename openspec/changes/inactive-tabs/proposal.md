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

## Out of scope this round

- Share-sheet and `webspace://` arrivals landing as tabs (they replace the
  site's page or open nested, exactly as today).
- A picker for in-app taps on links another site claims.
- Cross-domain pages as tabs: a cross-domain tap still opens the ephemeral
  nested screen. A tab is always in its site's domain, so the container
  question has one answer.
- Keep limits, pins, sweeping. "Close N parked" is the only hygiene.
- A warm second webview per site.

## Status

Design stage. The flow is captured in `design.md` and in a clickable
prototype (a static HTML simulator of the phone, the site strip, the drawer
tree, the Tabs sheet, the link menu, a memory panel with OS-pressure and
relaunch buttons, and an engine log). The delta spec under `specs/` holds the
requirements the prototype embodies. No code has been written against this
change.

## Capabilities

### New Capabilities
- `inactive-tabs`: per-site tab list with one active tab and N parked tabs, a
  parent tree, the new-tab and open-in-new-tab mechanisms, the
  capture/dispose/rebuild switch, the back-at-start rule, the Tabs sheet and
  drawer tree.

### Modified Capabilities
- `webview-pause-lifecycle`: `WebViewStateStorage` is keyed by
  `<siteId>/<tabId>`; PAUSE-009 capture points write the active tab's bytes.
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
- `SecureWebViewStateStorage` keyed by `<siteId>/<tabId>`; orphan sweep per
  tab; site delete removes the site's directory.
- UI: count pill on strip chips and drawer tiles, Tabs sheet, drawer tree
  rows, link long-press menu, "New tab" in the overflow.
- Kernel model: the `loaded` set and `Inv_CurrentLoaded` are unchanged (one
  webview per site). The tab list is state beside it, not inside it.
