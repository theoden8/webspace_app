# BUG-015 — URL bar shows a URL other than the page's

Status: open

## Symptom

The URL bar names a page the webview is not showing. It is noticed after
going back: the page returns to where it was, the bar does not. Faces seen
so far:

- iOS: a back swipe restores a page from the back/forward cache and the
  bar keeps the URL of the page that was left.
- Typing another site's URL into the bar opens it in a nested webview;
  closing that with its back button returns to the site with the typed
  URL still in the bar, next to a padlock computed from the site's real
  URL. It stays until the site navigates again.

## Root mechanism / invariant

The bar's text has two writers and only one of them is tracked.

- The webview reports URLs (`onLoadStop`, `onUpdateVisitedHistory`), which
  the site commits as `currentUrl` and the page rebuilds the bar with.
  `UrlBar.didUpdateWidget` copies `currentUrl` into the text field only
  when `currentUrl` *changes*.
- The user types into the same text field. When a submit leaves
  `currentUrl` where it was, no change arrives and the typed text outlives
  the edit.

A path that moves the page without an event, or ends an edit without
moving `currentUrl`, leaves the bar stale. The invariant: **outside an
active edit, the bar's text is `currentUrl`, and `currentUrl` is the URL
the webview last reported.** Normative rule:
[openspec/specs/navigation/spec.md](../../openspec/specs/navigation/spec.md)
(NAV-007).

## Fix attempts

1. **2026-04-10 — PR #174.** Wired `onUpdateVisitedHistory` into
   `onUrlChanged` beside `onLoadStop`, because WKWebView does not fire
   `onLoadStop` for a back/forward-cache restore. *Why partial*: covered
   the webview-to-`currentUrl` leg. The bar's own text buffer was left
   as it was, so a submit that did not navigate this webview still left
   the typed text behind.

2. **2026-09-23 — this change.** `UrlBar` awaits `onUrlSubmitted` and then
   shows `currentUrl` again. The main view's callback completes after it
   has committed the new URL (same-domain), or when the nested webview it
   opened is closed (cross-domain), so the bar lands on the right URL
   either way. Test: [test/url_bar_sync_test.dart](../../test/url_bar_sync_test.dart).
   *Why partial*: covers the submit path only; the gaps below remain.

## Known open gaps

- **An edit that never ends.** `didUpdateWidget` skips updates while
  `_isEditing`, which clears only when the field loses focus. On Android
  the back button hides the keyboard without taking focus from the field,
  so a later back navigates the page while the bar holds the old text.
  Not reproduced here.
- **The cross-domain redirect trade-off.** When a server-side redirect to
  another domain slips past `shouldOverrideUrlLoading`, the site keeps
  `currentUrl` on the last same-domain URL and opens the target nested,
  but the main webview still shows the target
  (`WebViewModel.getWebView`, `onUrlChanged`). The bar and the page
  disagree until the next navigation, by design.
- **The nested screen's bar shows the old URL until a submit commits.**
  The nested screen does not commit a submitted URL early the way the
  main view does, so on Android its bar holds the current page's URL
  until the new page commits. Committing early would feed an uncommitted
  URL into its `shouldOverrideUrlLoading` decision (NESTED-009/010).
- **No test covers the webview-to-`currentUrl` leg.** Attempt 1 has no
  automated test; a platform whose visited-history event goes quiet would
  recur without failing CI.
