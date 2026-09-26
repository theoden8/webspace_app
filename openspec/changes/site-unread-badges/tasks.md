## 1. State

- [x] 1.1 `unreadCountFromTitle`: leading `(N)` and a `(N)` closing the first title segment; `N+` and grouped digits.
- [x] 1.2 `SiteUnreadService`: page count with the 5 s clear delay, missed notifications with tag replacement, `markSeen`, `clearPageCount`, `forget`, `retainOnly`; notifies only on change.

## 2. Wiring

- [x] 2.1 `WebViewConfig.onTitleChanged`, fed from the site's own webview; `disposeWebView` clears the page count.
- [x] 2.2 `webNotification` handler records the post after the frame check.
- [x] 2.3 `_WebSpacePageState`: `isOnScreen`, `markSeen` on the site switch and on resume, `retainOnly` after delete and import, `forget` on archive close.

## 3. UI

- [x] 3.1 `SiteUnreadBadge` on both drawer tile layouts and the tab strip; `UnreadMenuIcon` on the app bar.

## 4. Tests

- [x] 4.1 Title parsing, clear delay, alternating titles, tag replacement, seen, forget, widgets.
- [x] 4.2 Structural gate on the call sites (`test/js/site_unread_wiring.test.js`).
