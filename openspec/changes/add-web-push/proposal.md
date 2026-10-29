## Why

A site with notifications on reaches the user only while its page runs, or when a
periodic wake reloads it and finds a higher unread count in its title
(NOTIF-013, NOTIF-014). Sites deliver their notifications by Web Push instead:
their server pushes to the site's service worker, which shows the notification.
Android WebView has no Push API (`PushManager`, `pushManager.subscribe`), so a
site never subscribes inside WebSpace and its server never sends anything a wake
could pick up. UnifiedPush gives an Android app a push endpoint a server can send
standard Web Push (RFC 8030, RFC 8291, VAPID) to, through a distributor app the
user picks, with no Google services; that endpoint is what the Push API needs.

## What Changes

- A new experimental feature, Web Push, offered only on Android through the
  Experimental group (DEVTOOLS-011), default off, and only while a UnifiedPush
  distributor is installed and picked.
- The notification polyfill gains the Push API: `PushManager`,
  `ServiceWorkerRegistration.pushManager` and `PushSubscription`, for a site with
  notifications on.
- A site is given a push endpoint only by the user's explicit permission, asked
  from the site on screen when its page subscribes, and never in the background.
  The prompt names the push server the endpoint is on and what giving it away
  costs: the site's server learns that server's address (a self-hosted one points
  at the user), and the distributor's connection to it carries the device's own IP,
  outside the site's proxy or Tor route. The grant names that server; a different
  server asks again.
- Each site gets its own registration under an opaque token, so neither the
  distributor nor two sites' servers can tie endpoints to a site name or to each
  other through WebSpace.
- A push is decrypted and handed to the site's own service worker `push` handler,
  run as the site in a headless check (NOTIF-016); what it shows is the site's
  notification. A push that shows nothing still posts one notice for the site, as
  Chrome does for a push that shows nothing.
- A push arriving while the app is not running wakes it the way the periodic
  refresh does (NOTIF-005-A), with no foreground service (NOTIF-015).
- Revoking (the site's Notifications row, turning notifications off, deleting the
  site, changing the distributor) unregisters the site and deletes its keys.
- Archive-tier and incognito sites are never offered the Push API. Backups and
  QR shares carry no grant, endpoint or key.
- NOTIF-002's "server-driven web push is out of reach" becomes true only where
  Web Push is not offered.
- iOS is not covered: no UnifiedPush distributor can run there, and APNs takes
  only pushes signed with the app developer's key (design.md, Non-Goals).

## Capabilities

### New Capabilities

- `web-push`: the Push API in a site's page, the per-site permission and what it
  discloses, registration and keys per site, turning a push into the site's
  notification, and revoking.

### Modified Capabilities

- `web-push-notifications`: NOTIF-002's server-push scenario names where Web Push
  is offered.
- `ip-leakage`: LEAK-007's coverage matrix gains the push channel, which the
  distributor runs outside every proxy.
- `developer-tools`: DEVTOOLS-011's table of experimental features gains Web Push,
  offered only on Android.

## Impact

- Android: the UnifiedPush `android-connector` dependency, a `PushService` declared
  in the manifest, and a plugin bridging registration, endpoints and messages to
  Dart, which starts the worker engine (`WorkerFlutterEngine`) when no engine runs.
- Page script: `lib/js/notification_polyfill.js` gains the Push API, and its
  sample config in `test/js/helpers/page_js_samples.js`.
- New pure Dart engines in `lib/services/`: the permission decision and the
  delivery plan; the wake engine (`BackgroundWakeEngine`) takes a push as a wake
  of one site, so the delivery reuses its headless check and route rules.
- A per-site grant store and the subscription secrets in a `SecureJsonStore`, an
  `OrphanStore` entry, an `AppPref` for the switch; a prompt, a site settings
  row and an App Settings row for the distributor; strings in
  `lib/l10n/app_en.arb` plus translations in their own commit.
- `openspec/unverified.tsv` lists every new requirement until its check exists.
