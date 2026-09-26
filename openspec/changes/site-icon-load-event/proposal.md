# Site icon from the load event

## Why

`SiteIconEngine` dropped every icon that arrived between `onLoadStart` and
`onLoadStop`, on the reasoning that Blink announces a document's icons only
after its load event. The premise holds, but `onLoadStop` is not the load
event. Blink announces the icons as soon as the `load` listeners return and
reports the load finished afterwards. WebView then posts `onPageFinished` while
the icon travels over IPC, so a page's own icon can reach the engine first. A
site whose only `rel=icon` downloads quickly then gets no webview icon, and
keeps the fetched favicon. The emulator tier's badge case failed this way on a
slow runner.

## What Changes

- **Icon-link watcher**: also reports `started` at document start and `loaded`
  from its `load` listener, under a token drawn per document, through a new
  `wsIconDocument` handler. The watcher's own `load` listener is registered
  before any page script, and Blink announces icons only after every `load`
  listener returns, so `loaded` is queued ahead of the document's first icon.
- **`SiteIconEngine`**: takes icons from the document's load event instead of
  from `onLoadStop`. `onDocumentStarted` and `onDocumentLoaded` join
  `onLoadStarted` and `onLoadFinished`, paired by origin in either order. A
  `loaded` report under another document's token is ignored. `onLoadStop`
  stays the fallback for a document that reports nothing, and a replaced
  document's `onLoadStop` does not open a document that already began.
- **`WebViewFactory`**: registers the handler beside `wsIconLinksChanged`, for
  the main frame only.

## Capabilities

### Modified Capabilities

- `icon-fetching`: ICON-009's "no main-frame load in flight" becomes "the
  document on screen has run its load event", with how that is known.

## Impact

- `lib/services/icon_link_watcher_shim.dart`, `lib/services/site_icon_engine.dart`,
  `lib/services/webview.dart`
- Tests: `test/site_icon_engine_test.dart`, `test/js/icon_link_watcher.test.js`,
  `test/browser/icon_link_watcher_real.test.js`, `integration_test/site_icon_test.dart`
