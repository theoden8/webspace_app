# Site icon before onLoadStart

## Why

The first page of a fresh launch on Android loses its own icon in the
emulator tier, four times in two days across both icon paths:

- **WebView's icons** (`onReceivedIcon`): the 32px icon that lands first is
  dropped, and only the 192px one that lands 600 ms later is taken.
  `SiteIconEngine` refuses an icon of at least the floor only while no page of
  the site is known, and only `onLoadStart` makes one known. So the icon
  reached Dart before the page's `onLoadStart`. That start is posted, while
  the icon is called from native code, and on a cold first WebView the icon
  overtakes it.
- **Declared links** (Site icons only): the page's load report and its link
  report can reach Dart before its `onLoadStart`. The late start then reads as
  a new document: it drops a fetch the links already claimed, or refuses the
  claim as a load still in flight, and the page gets no icon at all.

ICON-009 assumed `onLoadStart` arrives before anything from the document it
starts. It does not on the first page of a cold WebView.

## What Changes

- **`SiteIconEngine` holds an icon that arrives while no web document is
  known** (before the first start, or while the known document is not http(s),
  such as `about:blank`), and judges it against the next web document it
  learns of, by the mid-load rule ICON-009 applies to that document.
- **A start for the URL whose load report already arrived**, before that
  load's `onLoadStop`, is that document's late start, not a new document.
  `onDocumentLoaded` takes the watcher's load report, apart from
  `onLoadFinished` (`onLoadStop`), so the engine can tell the two apart.
- **The engine's decisions go to the app log** under `SiteIcon`, without URLs,
  so a device that loses an icon shows the order it saw.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `icon-fetching`: ICON-016, an icon or load report that reaches the app
  before its document's `onLoadStart` still counts for that document.

## Impact

- `lib/services/site_icon_engine.dart`, `lib/services/webview.dart`
- Tests: `test/site_icon_engine_test.dart`,
  `test/js/page_bridge_authority.test.js`,
  `integration_test/site_icon_test.dart` (prints a request and acceptance
  timeline)
- Bug record: [BUG-021](../../../../docs/bugs/021-site-icon-lost-to-callback-order.md)
