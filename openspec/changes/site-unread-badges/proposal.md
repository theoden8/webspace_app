# Unread badges on sites

## Why

A site that is not on screen gives no sign that something is waiting in it.
Chat and mail sites say how many messages are unread in their tab title
(`(3) Messenger`, `Inbox (3) - Mail`), and a site with notifications enabled
posts through the polyfill, but the drawer and the tab strip showed neither. A
user had to open every site to find out, or rely on OS notifications, which
need a per-site grant and OS permission and say nothing once dismissed.

## What Changes

- **`SiteUnreadService`** (`lib/services/site_unread_service.dart`): per-site
  unread state in memory. Two sources:
  - the count the page states in its title, read on every title change
    (`onTitleChanged`, which fires for in-place changes, not only on
    navigation). A title without a count clears it only after holding for
    5 s, so a page that alternates its title with a "New message" line does
    not blink the badge. The count goes with the page when its webview is
    disposed.
  - notifications the site posted while it was not on screen, counted in the
    `webNotification` handler after the NOTIF-010 frame check, with NOTIF-009's
    tag replacement. Cleared when the user switches to the site or returns to
    the app on it. Counted whether or not the OS lets the notification show.
- **Badge**: the page's count when it states one, otherwise the missed
  notifications. A count pill on the favicon of both drawer tile layouts
  (top-start, clear of the reorderable tile's overflow button), a trailing
  pill on each tab-strip tab, and a dot on the app bar's menu button while any
  other site in the drawer's webspace has one. Labelled from the existing
  `siteSettingsNotifications` string, so no new copy.
- **`WebViewConfig.onTitleChanged`**: set only for the site's own webview; a
  nested webview's page is not the site's.

## Capabilities

### New Capabilities

- `site-unread-badges`: UNREAD-001 to UNREAD-005.

### Modified Capabilities

- None. The archive audit (ARCH-006) needs no override: the state is held in
  memory only, touches no disk, schedules nothing, draws no OS UI, and a
  closed archive's sites are forgotten along with it.

## Impact

- `lib/services/site_unread_service.dart` (new),
  `lib/widgets/site_unread_badge.dart` (new), `lib/services/webview.dart`,
  `lib/web_view_model.dart`, `lib/main.dart`.
- Strings: none.
- Tests: `test/site_unread_service_test.dart`,
  `test/js/site_unread_wiring.test.js`.
