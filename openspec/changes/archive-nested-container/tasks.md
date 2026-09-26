## 1. Fix

- [x] 1.1 Thread `archiveContainerId` through the nested chain into the nested `WebViewConfig`.
- [x] 1.2 `_closeArchive` deletes `ws-<siteId>` for archive sites no app-tier site shares an id with.

## 2. Gates and records

- [x] 2.1 `nested_webview_posture_parity`: `archiveContainerId` from `KNOWN_GAP` to `POSTURE`; the field-parity test picks it up from the typedef.
- [x] 2.2 Structural test for the close-time sweep and its app-tier guard.
- [x] 2.3 BUG-019, linked from SEC-014 in the 2026-09-10 review.
