## 1. Engine

- [x] 1.1 `SiteIconEngine` holds icons while no web document is known and judges them against the next web document.
- [x] 1.2 `onDocumentLoaded` records the watcher's load report; a start for that URL before its `onLoadStop` keeps the document.
- [x] 1.3 Engine decisions logged under `SiteIcon`, without URLs.

## 2. Tests

- [x] 2.1 Engine: an icon before the first start, an icon during a blank start, held icons judged by the page they meet, a start after the load report with the links claimed before and after it, and a reload after `onLoadStop`.
- [x] 2.2 Emulator: `site_icon_test.dart` prints when each request arrived, each icon was sent and each icon was taken.
