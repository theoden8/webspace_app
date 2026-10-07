# BUG-027 — A site webview is built without some of the host's prompts

Status: **closed.** Every site webview, the root one whichever path builds it
first and the nested screen, takes one `WebViewHostHooks`
(`lib/services/webview_host_hooks.dart`) that `_WebSpacePageState` builds once.
Its fields are required and non-null, and `getWebView`, `getController` and
`InAppWebViewScreen` take the object whole, so a path that builds a webview
cannot leave a prompt out.

**Spec:** [tls-trust-prompt](../../openspec/specs/tls-trust-prompt/spec.md),
[external-scheme-handling](../../openspec/specs/external-scheme-handling/spec.md),
[web-microphone-access](../../openspec/specs/web-microphone-access/spec.md) MIC-014,
[link-intent-routing](../../openspec/changes/route-outbound-via-lir/specs/link-intent-routing/spec.md) LIR-014
**Related:** [BUG-024](024-nested-posture-drift.md), the same shape for the
site's posture rather than the host's answers

## Symptom

A site behaves as if a prompt did not exist: a self-signed certificate
cancels silently, an HTTP sign-in never asks, a captcha's popup never opens, a
camera or microphone request is denied without a popup, `intent://` links do
nothing, a long-press opens no link menu. It happens to a site whose webview
was first built by `getController` (a site created from a shared link, a
search that loads in place, a link intent) rather than by the page's
`IndexedStack`, and lasts until the webview is rebuilt.

## Root mechanism

`getWebView` took four positional and twenty-one optional named host hooks,
each defaulting to null, which meant "no prompt". The `IndexedStack` passed
them all; `getController`, which builds the same webview when the frame has
not, passed four. The cached webview then served that site for the session.
The nested screen took a third, different subset and re-implemented the
certificate, sign-in and popup prompts with its own context. A per-slot
`isActive` closure captured the slot's list index at build time, so after a
site ahead of it was deleted the on-screen check compared the wrong slot.

**Invariant:** every webview that runs as a site gets every host answer.

## Fix attempts

1. **2026-09-25, d58b1c02 (#345).** *What:* `getController` forwarded the new
   outbound-routing hook to the webview it builds, and
   `outbound_link_funnel.test.js` required every `getWebView`/`getController`
   call in `main.dart` to pass it. *Why:* a webview built by `getController`
   never routed outbound links. *Why partial:* it covered the one hook it
   added; the prompts that already existed stayed absent on that path.

2. **2026-10-07, refactor/webview-internals.** *What:* the hooks became one
   `WebViewHostHooks` with required fields, built once in `main.dart` and
   passed whole to `getWebView`, `getController` and `InAppWebViewScreen`; the
   on-screen check became an identity test (`onScreen`), and the nested
   screen's copies of the prompts and the popup were deleted. The
   `outbound_link_funnel` wiring checks it made redundant were retired.
   *Why:* only a type makes "every hook, on every path" hold for the next hook
   too.

## Known open gaps

- The slot's HTML cache (`initialHtml`, `onHtmlLoaded`, `shouldFetchHtml`)
  is still the `IndexedStack`'s to pass: a webview `getController` builds
  first loads live and saves no snapshot until it is rebuilt. That fails
  safe (no stale page, no write), unlike the prompts.
