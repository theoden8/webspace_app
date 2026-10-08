# BUG-031 — The content blocker's early `<style>` becomes the document root

Status: **open, fix in review.** The shim waits for the root and a gate runs
every dumped shim on a rootless document; open until the reporter of
[#405](https://github.com/theoden8/webspace_app/issues/405) confirms on a
release.

**Spec:** [content-blocker](../../openspec/specs/content-blocker/spec.md) CB-019
**Related:** [BUG-001](001-white-screen.md), the same symptom from an
unpainted surface; its gap #17 ruled this cause out, wrongly (below)

## Symptom

A site with the content blocker on, directly or through Tracking Protection,
sometimes opens on a white page, or black under a dark theme. It follows a
fresh load: a shortcut whose site was not loaded, a link tap, a site switch,
saving the site's settings. Repaint, texture mode and recreating the webview do
not help; a reload sometimes does. Turning the content blocker off makes it go
away. The reporter's console probe, on ChatGPT and Brave Search:

```
root=STYLE roots=1 html=0 body=none state=complete blocker=ROOT
```

The page finished loading, and the document's only element is the blocker's
`<style id="_webspace_content_blocker_style">`.

## Root mechanism

The early CSS shim is injected twice: as a DOCUMENT_START user script, and by
`evaluateJavascript` from `onLoadStart` (`lib/services/webview.dart`).
Android posts `onPageStarted` asynchronously, so the second copy can land on a
document that has committed but whose parser has not yet seen a byte. Such a
document has no element child, and it exists whenever the server sends its
headers before its body, which streamed pages such as ChatGPT and Brave Search
do. The shim fell back to `document.appendChild(style)`, which made the
`<style>` the root; a document has one, so the parser's `<html>` was never
attached and the whole page was parsed into nothing.

The DOCUMENT_START copy is safe: Android WebView and WKWebView run
document-start scripts once the document element exists. Puppeteer's
`evaluateOnNewDocument` runs earlier, so it reproduces the race.

**Invariant:** no shim appends a node to the `Document` itself.

## How it hid

- **#101 (2026-03-04)** added the content blocker with both the
  `|| document` fallback and the `onLoadStart` copy.
- **#270 (2026-05-01)** saw the mechanism in the browser tier: under
  `evaluateOnNewDocument` the `<style>` became the root and the page did not
  parse. It moved the early-CSS tests to post-load, reasoning that production
  DOCUMENT_START runs after the document element exists. That is true of the
  user script, not of the `onLoadStart` copy.
- **BUG-001 gap #17 (2026-10-04)** ruled the fallback out with a headless
  experiment that served the page whole, so `<html>` existed at commit. With
  headers sent before the body it does not:

  | server sends | `documentElement` after commit |
  |---|---|
  | headers, then the body 1.5s later | `null` |
  | `<!doctype html>`, then the rest 1.5s later | `null` |
  | the whole page at once | `HTML` |

## Fix attempts

1. **2026-10-08, branch `claude/adoring-lamport-ukzlty` (#405).** *What:*
   `buildContentBlockerEarlyCssShim` inserts into `head` or the document
   element, and on a rootless document waits with a `MutationObserver` on
   `document`, skipping the insert if a copy got there first. The early-CSS
   browser tests run at document start again, with a test that the page keeps
   its own root; `test/js/shim_document_root.test.js` runs every dumped
   fixture on a rootless document and fails if one becomes its root. *Why:*
   the shim is the one owner of where its `<style>` goes, so fixing it there
   covers both copies and any later caller. *Why partial:* the gate sees only
   shims dumped by `tool/dump_shim_js.dart`; a page script never dumped as a
   fixture is outside it.

## Known open gaps

1. User scripts reinjected from `onLoadStart` (`reinjectOnLoadStart`) run in
   the same window. They are the user's own code, so no gate covers them.
2. Not this bug, found beside it: the DOCUMENT_START copy carries
   `config.initialUrl`'s hides, and both later copies stop at the
   `getElementById(ID)` guard, so after a cross-host navigation in the same
   webview the page keeps the first host's selectors.
