# Site icon before onLoadStop

## Why

`SiteIconEngine` dropped every icon that arrived between `onLoadStart` and
`onLoadStop`, on the reasoning that Blink announces a document's icons only
after its load event, so a mid-load icon belongs to the document being
replaced. The premise holds, but `onLoadStop` is not the load event: WebView
posts `onPageFinished` from `didStopLoading` through a handler, and calls
`onReceivedIcon` straight from native code, so a page's own icon can arrive
first. A site whose only `rel=icon` downloads quickly then gets no webview
icon and keeps the fetched favicon. The emulator tier's badge case failed this
way on a slow runner.

A report from the page cannot fix the order either: a JS bridge call reaches
Dart through a posted Java message too, and the emulator showed the icon
overtaking one.

## What Changes

- **`SiteIconEngine`** decides a mid-load icon by both documents it can belong
  to. It remembers whether the replaced page was on the site's host with its
  icon links unedited, and takes a mid-load icon when that holds and the
  loading page (whose committed URL `onLoadStart` carries) is the site's too.
  A page that is not http(s) announces no icons, so the page before it counts.
  After `onLoadStop`, only the loaded page counts, as before.

## Capabilities

### Modified Capabilities

- `icon-fetching`: ICON-009's "no main-frame load is in flight" becomes "both
  documents a mid-load icon can belong to are the site's".

## Impact

- `lib/services/site_icon_engine.dart`
- Tests: `test/site_icon_engine_test.dart`, `integration_test/site_icon_test.dart`
