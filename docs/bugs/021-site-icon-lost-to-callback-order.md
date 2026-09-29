# BUG-021 — A page's own icon is lost to the order WebView's callbacks reach Dart

Status: open

**Spec:** [icon-fetching](../../openspec/specs/icon-fetching/spec.md) ICON-009,
ICON-013; changes [site-icon-mid-load](../../openspec/changes/site-icon-mid-load/specs/icon-fetching/spec.md)
and [site-icon-before-load-start](../../openspec/changes/site-icon-before-load-start/specs/icon-fetching/spec.md)
(ICON-016)
**Tests:** [test/site_icon_engine_test.dart](../../test/site_icon_engine_test.dart)
(each order as an engine case),
[integration_test/site_icon_test.dart](../../integration_test/site_icon_test.dart)
(the Android emulator tier, `scripts/run_android_site_icon_tests.sh`, which
prints a request and acceptance timeline)

## Symptom

A site keeps the fetched favicon, or no page icon at all, although its page
declares a usable one. In CI, `site_icon_test.dart` "keeps the largest of
several icons, whatever order they land in" fails on the first page of a fresh
launch, and the other pages of the same pass succeed:

- WebView pass: `accepted=[192x192]`, the 32px icon that landed first dropped.
- Site icons only pass: `accepted=[]`, with the app's own fetch of the declared
  links either run and dropped, or never started.

## Root mechanism / invariant

`SiteIconEngine` decides whose an icon is from the order of the callbacks
around it: `onLoadStart`, `onLoadStop`, `onReceivedIcon`, and the watcher's
load and link reports. None of those orders is guaranteed. On Android
`onPageStarted` and `onPageFinished` are posted to the looper, the JS bridge
posts too, and `onReceivedIcon` is called straight from native code, so any
of them can reach Dart ahead of a callback that logically precedes it, most
of all on a cold first WebView whose looper is busy.

The invariant: **an event the engine cannot place in a document yet must be
kept until it can be, not judged against whatever document happens to be
current.** Each fix below placed one more kind of early event.

## Fix attempts

1. **2026-09-26 — PR #636** (`03bffbe`). The engine dropped every icon between
   `onLoadStart` and `onLoadStop`, reasoning that Blink announces icons only
   after the load event. It began taking a mid-load icon when both documents it
   can belong to are the site's. *Why*: `onPageFinished` is posted, so a page's
   own icon arrived before it and was lost. *Why partial*: it kept the
   assumption that `onLoadStart`, "posted at commit", arrives before any icon
   of the page it starts. On the first page of a cold WebView the icon
   overtakes that post too, and the engine, knowing no page yet, dropped it.
   The Site icons only path (#649, 2026-09-29) inherited the same assumption
   for the watcher's reports.

2. **2026-09-29 — PR #652.** An icon that arrives while no web document is
   known is held and judged against the next web document the engine learns
   of, by the mid-load rule. `onDocumentLoaded` takes the watcher's load
   report, and a start for that URL before its `onLoadStop` is the document's
   late start, not a new document. The engine logs each decision under
   `SiteIcon` without URLs. *Why*: all four CI failures were the first page of
   a fresh launch, and the WebView case can only be an icon handled before
   `onLoadStart`: nothing else refuses a 32px icon and then takes a larger
   one. *Why partial*: see open gaps.

## Known open gaps

- An icon of a later page that overtakes that page's `onLoadStart` while the
  previous page is still the known document is judged as the previous page's.
  It is taken if the previous page is the site's, even when the page it came
  from is a login bounce on another host. Only the first page, and pages after
  a non-web one, are held.
- If the watcher's reports are ever dropped rather than late (a bridge that is
  not up when the load event fires), the page never claims its links, and
  nothing retries. The `SiteIcon` log tells the two apart: a late report shows
  `loadReported=true` at the start, a dropped one shows no `documentLoaded`
  line at all.
