# Unread badges on sites

## Why

A site with notifications enabled posts through the polyfill, and the post
reaches the OS shade, but inside the app nothing marked the site. Once the OS
notification was dismissed, or when OS permission was denied, the only way to
find out a site had posted was to open it.

## What Changes

- **`SiteUnreadService`** (`lib/services/site_unread_service.dart`): per-site
  count of web notifications posted while the site was not on screen, in
  memory. Counted in the `webNotification` handler after the NOTIF-010 frame
  check, with NOTIF-009's tag replacement, whether or not the OS shows the
  notification. Cleared when the user switches to the site (a notification tap
  included) or returns to the app on it.
- **Badge**: a count pill on the favicon of both drawer tile layouts
  (top-start, clear of the reorderable tile's overflow button), a trailing pill
  on each tab-strip tab, and a dot on the app bar's menu button while any site
  in the drawer's webspace has a count. Labelled from the existing
  `siteSettingsNotifications` string, so no new copy.

## Capabilities

### New Capabilities

- `site-unread-badges`: UNREAD-001 to UNREAD-003.

### Modified Capabilities

- None. The archive audit (ARCH-006) needs no override: archive-tier sites
  cannot post (`effectiveNotificationsEnabled` is false), the state is held in
  memory only, and a closed archive's sites are forgotten along with it.

## Impact

- `lib/services/site_unread_service.dart` (new),
  `lib/widgets/site_unread_badge.dart` (new), `lib/services/webview.dart`,
  `lib/main.dart`.
- Strings: none.
- Tests: `test/site_unread_service_test.dart`,
  `test/js/site_unread_wiring.test.js`.
