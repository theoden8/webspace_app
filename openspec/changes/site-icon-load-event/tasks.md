## 1. Reports

- [x] 1.1 The icon-link watcher reports `started` and `loaded` under a per-document token through `wsIconDocument`, main frame only.
- [x] 1.2 `WebViewFactory` registers the handler and forwards both reports to the engine.

## 2. Engine

- [x] 2.1 `SiteIconEngine.onDocumentStarted` / `onDocumentLoaded`, paired with `onLoadStarted` by origin in either order; `onLoadStop` as the fallback.

## 3. Tests

- [x] 3.1 Engine: every interleaving of the reports with WebView's load events, a late report from a replaced document, and the fallback.
- [x] 3.2 jsdom: one token per document, `loaded` made inside the load event, subframes silent, a throwing bridge leaves the watcher running.
- [x] 3.3 Real Chromium: the `loaded` report reaches the server before Chrome requests the page's icon.
- [x] 3.4 Emulator: the multi-icon page takes 32px then 192px, and the badge page takes its own icon, whether or not either lands before `onLoadStop`.
