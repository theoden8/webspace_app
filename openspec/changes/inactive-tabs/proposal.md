## Why

WebSpace gives a site its own cookies and settings, but only one page. Open a
second page from GitHub and either the first one is gone (in-domain navigation
replaces `currentUrl`) or the second one is (a cross-domain hop lives in a
nested `InAppWebViewScreen` and dies on back). Nothing accumulates. That is the
one thing a browser does that this app does not, and it is the reason saved-for-
later products fail: inactive tabs are the reading list, in place, with the
session that opened them.

Link-intent routing (`link-intent-routing`, LIR-001..LIR-012) was a first step:
it decides which site an inbound URL belongs to. It then either replaces the
site's page or opens a nested screen. It never keeps anything. This change gives
the resolver somewhere to put a URL.

## What Changes

- A site owns a list of **pages**. A page is a URL, a title, the page it was
  opened from, and the site's saved navigation state for it. Exactly one page
  per site is **active** (bound to the site's single resident webview); every
  other page is **parked** and costs no renderer.
- **Sideways leaves park, backwards leaves close.** Switching to another page,
  opening a link in the background, sharing a URL in, or leaving the app parks
  the page. The system back gesture at the start of a child page's history
  closes it and returns to its parent, as Chrome does.
- Four ways a page accumulates: long-press a link and open it in the
  background; park the page you are on; a shared URL lands in its site's list
  without stealing the screen; a cross-domain hop kept by switching away.
- Pages form a **tree** under their site (parent = the page that opened it),
  shown in the drawer under each site and in a per-site Pages sheet reached
  from the tab strip and the app bar.
- The link-intent dispatcher grows an "add to <site>" outcome next to its
  existing "open in <site>", and in-app taps on links another site claims get
  the same picker, so a GitHub link tapped on Mastodon can open in GitHub's
  container with GitHub's login.
- Per-site hygiene on the Behaviour screen: keep parked pages until closed, or
  sweep them after a day, a week, or a month; pinned pages are exempt.
- The per-site feature audit (ARCH-006 shape) for pages: incognito pages never
  reach disk, Always open Home reverts only the active page, kiosk hides the
  page UI, archive-tier pages live under the archive key, the QR share never
  carries pages.

## Status

Design stage. The flow is captured in `design.md` and in a clickable
prototype (a static HTML simulator of the phone, the tab strip, the drawer
tree, the Pages sheet, the link menu, the share arrival and the policy knobs).
The delta spec under `specs/` holds the requirements the prototype embodies;
the knobs it exposes are listed as open questions in `design.md` and are not
yet normative. No code has been written against this change.

## Capabilities

### New Capabilities
- `inactive-tabs`: per-site page list with one active page and N parked pages,
  a parent tree, four accumulation paths, sideways/backwards lifecycle rule,
  Pages sheet and drawer tree, per-site keep limit, and the cross-site routing
  picker for in-app link taps.

### Modified Capabilities
- `link-intent-routing`: `DispatchOpenInMain` gains a parked variant; the
  LIR-010 picker gains "Add to <site>" rows.
- `nested-url-blocking`: a nested screen becomes the viewer for a child page;
  its back-at-history-start pop is the "backwards closes" rule.
- `webview-pause-lifecycle`: `WebViewStateStorage` is keyed by page, not site;
  PAUSE-009 capture points write the active page's bytes.
- `site-behaviour`: "Keep parked pages" row.
- `always-open-home`, `incognito-mode`, `kiosk-mode`, `archive`,
  `site-settings-qr`, `settings-backup`: one scenario each for what a page
  does under that feature (see the audit table in `design.md`).

## Impact

- `WebViewModel`: `pages`, `activePageId`; `currentUrl`/`pageTitle` become the
  active page's fields (getter-compatible, JSON migration synthesises one page
  from a legacy `currentUrl`).
- New pure-Dart engine `lib/services/page_lifecycle_engine.dart` (activate,
  park, close-with-reparent, back-at-start, sweep).
- `SecureWebViewStateStorage` keyed by `<siteId>/<pageId>`; orphan sweep runs
  per page.
- `LinkIntentDispatchEngine`: `DispatchOpenInMain.activate: false` and a
  `DispatchAddToSite` follow-up from the picker.
- UI: page count pill on tab-strip chips and drawer tiles, Pages sheet, drawer
  tree rows, link long-press menu, `_DispatchPickerSheet` rows.
- Kernel model: the `loaded` set and `Inv_CurrentLoaded` are unchanged (one
  webview per site); the page list is state beside it, not inside it. If the
  activate/park actions touch shared runtime state, run the mix gate in
  `formal/`.
