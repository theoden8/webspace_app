# Design

## Context

- Android WebView has no Push API, no `Notification` and no
  `ServiceWorkerRegistration.showNotification` (MDN browser-compat-data:
  `webview_android: false` for each). It does run service workers.
- The notification polyfill (`lib/js/notification_polyfill.js`, NOTIF-002)
  already defines `Notification` and bridges page-context `showNotification` to
  `NotificationService` through the `webNotification` handler, in a site's own
  webview and in a wake's headless check (`PageHandlers.registerPageHandlers`).
- A background wake is a step table (`BackgroundWakeEngine.table`) that
  `activation.tla` takes whole: it opens headless checks under the route rules
  (`RouteFree`, `ProcessRoute`, PROXY-008) and closes them when the app returns.
- When no Flutter engine is running, the refresh worker starts one with no
  activity (`WorkerFlutterEngine`), and `MainActivity` stops it before building
  its own, so two copies of the app's Dart state never run at once.
- UnifiedPush's Android connector (`org.unifiedpush.android:connector`, spec
  AND_3 from connector 3.0) registers an app under an *instance* name, passes a
  VAPID key to the distributor, and wakes the app's declared `PushService` with
  each message. The connector generates a key set per registration and decrypts
  what it can; a message it cannot decrypt arrives with `decrypted` false and the
  ciphertext as content (as the official Flutter wrapper documents).
- No UnifiedPush distributor can run on iOS (unifiedpush.org FAQ: iOS runs no
  background service for one).

## Goals / Non-Goals

**Goals:**

- A site's own Web Push, delivered to its own service worker code, with the
  user deciding per site, knowingly, whether the site may learn the push
  server's address.
- Every decision that is not a platform call in a pure engine with a table test;
  the delivery a path the model already checks.

**Non-Goals:**

- **iOS.** The only channel that wakes an iOS app is APNs, which takes only
  pushes signed with the app developer's key. Web Push on iOS would need a relay
  the project runs, accepting Web Push from sites and sending a content-free
  wake through APNs, as ntfy's iOS app does with `upstream-base-url` (only a
  message id goes through ntfy.sh; the device fetches the message). That relay
  would learn when each allowed site pushes and the device's APNs token: a
  decision of its own, for a separate change.
- **Linux.** UnifiedPush has a D-Bus spec and distributors (KUnifiedPush); a
  later change can reuse everything here but the Kotlin plugin.
- **Holding a connection of WebSpace's own** (alternatives under Decision 1).
- `pushsubscriptionchange` beyond WEBPUSH-003's re-ask, and `notificationclick`
  beyond opening the site (NOTIF-003).

## Decisions

### 1. UnifiedPush, through the official Android connector

One distributor app holds one connection for every app on the device; WebSpace
registers each allowed site with it and is woken per message.

- *FCM*: needs Google Play services, which the F-Droid build has none of, and a
  website's server cannot send to FCM directly, so the project would run a relay.
  Rejected.
- *WebSpace's own websocket to a push server*: works only while WebSpace runs; in
  the background Android keeps a connection open only for an app with a
  foreground service, which NOTIF-015 rules out. Keeping that connection is the
  distributor's job, done once for all apps.
- *A MollySocket-style bridge* (a self-hosted server that keeps the service's own
  connection and sends a content-free UnifiedPush wake, as MollySocket does for
  Signal): it speaks one service's protocol and holds that service's credentials.
  For arbitrary sites it would hold each site's session on the user's server and
  run the site there. A site's own Web Push gives the same wake with no
  credential leaving the device. A bridge that sends content-free pushes would
  still be delivered by WEBPUSH-005's notice.
- *The official Flutter wrapper* (`unifiedpush` on pub.dev): it brings its own
  way of running Dart for a background message, beside `WorkerFlutterEngine`,
  and two engines must never hold the app's state at once. A Kotlin plugin over
  the connector, feeding the existing engine, keeps one owner.

### 2. WebSpace's own keys, its own decryption

Each site's P-256 key pair and auth secret are made by WebSpace and kept in a
`SecureJsonStore` on `Keystores.credentials` (WEBPUSH-008), with the
registration token, the endpoint and the granted origin, one entry per site.
The site is given WebSpace's public key, so the connector never decrypts a
site's message and hands over the ciphertext; WebSpace decrypts it (RFC 8291
`aes128gcm`) in a pure Dart engine over the crypto packages the app already
depends on (`pointycastle`, `cryptography`), with RFC 8291's worked example as
its test.

- *The connector's key set*: fewer lines, but its keys live where the connector
  keeps them, outside the app's keychain-backed store, and the backup and orphan
  rules could not reach them. Rejected.

### 3. The site's service worker code, run in a worker the delivery creates

The subscription records the registration's scope and `active.scriptURL`.
Delivery opens the site (its live page, or a headless check) and the polyfill
starts a dedicated worker from a blob: a prelude that gives the script a
service-worker-shaped scope (`self.registration` whose `showNotification` posts
through the page's bridge, `clients.matchAll()` empty, `skipWaiting`,
`addEventListener` for `push`), then `importScripts(scriptURL)`, then a `push`
event carrying `PushMessageData` (`text`, `json`, `arrayBuffer`, `blob`) whose
`waitUntil` the prelude awaits up to a deadline. A blob worker has the page's
origin, so the script reads the site's own IndexedDB and caches in the site's
container, and the worker shims (`worker-shim-propagation`) reach it.

- *Injecting into the real service worker* (rewriting its script on fetch): the
  site would run a script it never served, the browser's byte-compare update
  check would churn, and every site's service-worker fetches would pass through
  the rewrite, not only a delivery's. Rejected.
- *The notice only*: kept as the floor (WEBPUSH-005), for a script that throws,
  needs real `clients`, or shows nothing.

### 4. A push is a wake of one site

`BackgroundWakeEngine` gains a push input: a plan of one site, live or headless,
under the same skips and route rules, whose middle hands the payload to the page
instead of reading a title. The delivery then takes the wake's checked behaviour
(route claims, closing on return to the foreground, one wake at a time) and its
model, and adds an input to an existing flow rather than a new flow sharing
`headless` and the route with it.

- *A separate delivery engine*: a second flow over the same variables, whose
  interleavings with the wake would all need modelling. Rejected.

### 5. The native side mirrors the refresh worker

The connector's `PushService` hands each message to a dispatcher like
`NotificationRefreshDispatcher`: to the running engine's channel when one is
bound, otherwise to a `WorkerFlutterEngine` it starts, once Dart says it is
ready, then stops it. Messages queue and are delivered one at a time.

### 6. Permission is an engine; the prompt is the page's

A pure engine decides each `subscribe()` from the site's state (offered, on
screen, a prompt already up, a grant and its origin, the distributor's current
origin) into a sealed answer: refuse with a reason, ask with the facts the prompt
shows (site, distributor, push server host, whether the site is proxied or on
Tor), or hand over the existing endpoint. The prompt is a `Dialog*Prompts`
dialog over the site, with no as its default.

### 7. What each party learns

| Party | Learns | Through |
|---|---|---|
| The site's server | the push server's origin and the site's endpoint path | the subscription it is given |
| The push server | the device's IP, which sites' servers push and when, and how much | the distributor's connection; the servers' requests |
| The distributor app | an opaque token per site | the registration name (WEBPUSH-004) |
| Anyone with the backup | nothing about push | WEBPUSH-008 |

A self-hosted push server is the user's own, so its origin can point the site at
the user, and an origin shared by all allowed sites lets their servers' owners
compare notes. The prompt says both (WEBPUSH-003).

## Risks / Trade-offs

- [A site's service worker needs what a dedicated worker lacks] → the notice
  floor; the delivery log says why the handler did not run.
- [The distributor delays delivery under Doze] → the distributor's own
  constraint, as for every UnifiedPush app; the periodic wake still runs
  (NOTIF-005-A).
- [A distributor refuses a registration without VAPID] → a site must pass an
  `applicationServerKey` (WEBPUSH-002), which is handed to the distributor.
- [The connector's Tink dependency conflicts with another library's] → the
  connector's documented fix, forcing one `tink-android` version.
- [A new input on the wake's table multiplies interleavings] → measured: the
  base config's `Finished in` before and after, in the PR.

## Migration Plan

New and off by default: no data migrates. Turning the switch off unregisters
every site and deletes its keys (WEBPUSH-007), which is also the rollback.

## Open Questions

- The connector version to pin, and its exact Kotlin API, settle in the first
  task.
