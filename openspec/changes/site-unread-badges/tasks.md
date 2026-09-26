## 1. State

- [x] 1.1 `SiteUnreadService`: per-site notification count with tag replacement, skipped while the site is on screen; `markSeen`, `forget`, `retainOnly`; notifies only on change.

## 2. Wiring

- [x] 2.1 `webNotification` handler records the post after the frame check.
- [x] 2.2 `_WebSpacePageState`: `isOnScreen`, `markSeen` on the site switch and on resume, `retainOnly` after delete and import, `forget` on archive close.

## 3. UI

- [x] 3.1 `SiteUnreadBadge` on both drawer tile layouts and the tab strip; `UnreadMenuIcon` on the app bar.

## 4. Tests

- [x] 4.1 Counting, tag replacement, on-screen posts, seen, forget, widgets.
- [x] 4.2 Structural gate on the call sites (`test/js/site_unread_wiring.test.js`).
