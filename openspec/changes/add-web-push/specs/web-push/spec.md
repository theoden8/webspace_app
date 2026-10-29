# Web Push

## Purpose

Lets a site deliver its notifications by Web Push, its server pushing to the site's service worker as it does in a browser, through a push channel the user picks, and only for the sites the user has explicitly allowed to learn that channel's address.

## ADDED Requirements

### Requirement: WEBPUSH-001 - Offered on Android through UnifiedPush, as an experiment

Web Push SHALL be reachable only on Android, only while developer mode and the Web Push switch in the Experimental group are on (DEVTOOLS-011), and only while a UnifiedPush distributor is installed and picked in App Settings. The switch SHALL default off. Elsewhere a page SHALL see no Push API and the app SHALL show no push setting.

iOS is excluded because no UnifiedPush distributor can run there (iOS runs no background service for one) and the only channel that wakes an iOS app, APNs, accepts only pushes signed with the app developer's key, which no site's server holds.

#### Scenario: Android with a distributor

- **GIVEN** Android with developer mode and Web Push on, and a distributor installed
- **WHEN** the user opens App Settings
- **THEN** a Push distributor row lists the installed distributors and the one picked

#### Scenario: No distributor installed

- **GIVEN** Android with developer mode and Web Push on, and no distributor installed
- **WHEN** a site's page reads `ServiceWorkerRegistration.prototype.pushManager`
- **THEN** it is undefined, as it is with the switch off
- **AND** the Push distributor row says that none is installed

#### Scenario: iOS

- **GIVEN** an iOS build with developer mode on
- **WHEN** the user opens App Settings, or a page looks for `PushManager`
- **THEN** there is no Web Push switch, no push setting and no Push API

### Requirement: WEBPUSH-002 - The page sees the Push API only where it may ask

Where Web Push is reachable, the notification polyfill SHALL define `PushManager` (with `supportedContentEncodings` of `["aes128gcm"]`), `ServiceWorkerRegistration.prototype.pushManager` and `PushSubscription` for a site whose notifications are on (NOTIF-004), on the site's own origin. `subscribe()` SHALL require `userVisibleOnly: true` and an `applicationServerKey`, and reject with the error a browser gives otherwise. `permissionState()` SHALL report `prompt` before the user has answered, `granted` once allowed and `denied` once refused. A site with notifications off, an archive-tier site (ARCH-006) and an incognito site SHALL see no Push API.

#### Scenario: A site with notifications on

- **GIVEN** Web Push is reachable and site A has notifications on
- **WHEN** A's page calls `registration.pushManager.permissionState({userVisibleOnly: true})`
- **THEN** it resolves to `prompt`

#### Scenario: A subscription without a server key

- **GIVEN** Web Push is reachable and site A has notifications on
- **WHEN** A's page calls `subscribe({userVisibleOnly: true})` with no `applicationServerKey`
- **THEN** the promise rejects and the user is not asked

#### Scenario: An incognito site

- **GIVEN** Web Push is reachable and site A is incognito
- **WHEN** A's page looks for `pushManager`
- **THEN** it is undefined

### Requirement: WEBPUSH-003 - A site gets an endpoint only by the user's explicit permission

A site's page SHALL be given a push endpoint only after the user allows it, in a prompt shown over that site while it is on screen. The prompt SHALL name the site, the distributor and the host of the push server the endpoint is on, and SHALL say, before the user answers, that:

1. the site's server will learn that push server's address, which for a self-hosted server can identify the user;
2. the distributor's connection to that server carries the device's own IP address and does not go through the site's proxy or Tor route, and the push server sees when, and how much, each allowed site sends.

For a site whose traffic goes through a proxy or Tor, the prompt SHALL say first that the push channel does not. The default answer SHALL be no; dismissing the prompt SHALL refuse it. A `subscribe()` from anywhere the user cannot see (a headless check, a page off screen) SHALL be refused without asking, and so SHALL one asked while another site's prompt is up. The grant SHALL name the push server's origin; once the picked distributor's endpoint for the site is on another origin, the grant SHALL lapse and the site SHALL be asked again before it is given that endpoint.

#### Scenario: The user allows a site

- **GIVEN** site A is on screen with notifications on, and the distributor's server is `push.example.org`
- **WHEN** A's page calls `subscribe()` with a server key and the user taps Allow
- **THEN** the promise resolves to a subscription whose endpoint is on `push.example.org`
- **AND** the prompt named `push.example.org` and said what the site and the push server learn

#### Scenario: The user dismisses the prompt

- **GIVEN** the prompt for site A is up
- **WHEN** the user dismisses it
- **THEN** `subscribe()` rejects, `permissionState()` reports `denied`, and A is given no endpoint

#### Scenario: A proxied site

- **GIVEN** site A goes through Tor
- **WHEN** A's page calls `subscribe()`
- **THEN** the prompt says first that the push channel does not go through Tor

#### Scenario: A subscription from the background

- **GIVEN** a background wake checks site A headless
- **WHEN** A's page calls `subscribe()`
- **THEN** it rejects and no prompt is shown

#### Scenario: The push server changes

- **GIVEN** site A was allowed for `push.example.org`
- **WHEN** the distributor's endpoint for A moves to `push.other.net`
- **THEN** A's subscription is dropped and A is asked again before it is given the new endpoint

### Requirement: WEBPUSH-004 - Each site its own registration, named by nothing that identifies it

Each allowed site SHALL have its own registration with the distributor, named by a token minted for that registration that carries neither the site's id, name nor host, so that the distributor learns no site identity from WebSpace and no two sites share an endpoint. Re-registering a site after it was revoked SHALL mint a new token.

#### Scenario: Two sites

- **GIVEN** sites A and B are both allowed
- **THEN** their endpoints differ
- **AND** neither registration's name contains A's or B's id, name or host

### Requirement: WEBPUSH-005 - A push becomes the site's notification

A push SHALL be decrypted as RFC 8291 `aes128gcm` with the site's keys; one that does not decrypt SHALL be dropped and logged. A decrypted push SHALL be handed, as a `push` event carrying its data, to the site's own service worker script, the one the subscription was made on, run as the site: in its container, through its proxy and blockers, with its shims, as a headless check runs (NOTIF-016), or in its live page when it has one. A notification that handler shows SHALL post as the site's (NOTIF-002), attributed by the subscription, never by anything in the payload. When the handler shows nothing before it settles, or cannot run, the app SHALL post one notification for the site saying it sent something, as a browser does for a push that shows nothing.

#### Scenario: The handler shows a notification

- **GIVEN** site A is allowed and its service worker shows a notification for each push
- **WHEN** A's server pushes a message
- **THEN** that notification is posted, tagged with A's site id

#### Scenario: The handler shows nothing

- **GIVEN** site A's service worker handles a push without showing a notification
- **WHEN** A's server pushes a message
- **THEN** one notification for A is posted, saying A sent something

#### Scenario: A payload names another site

- **GIVEN** site A is allowed
- **WHEN** a push to A's endpoint carries data naming site B
- **THEN** whatever it shows is posted as A's

### Requirement: WEBPUSH-006 - A push wakes the app without keeping it running

A push SHALL reach the site whether or not the app is running: when it is not, the push SHALL start the app's background engine as the periodic refresh does (NOTIF-005-A), deliver, and end it. No foreground service SHALL be started for it (NOTIF-015). A push SHALL be delivered under the route rules a wake's headless check follows (NOTIF-016, PROXY-008): one that cannot run beside what runs SHALL wait for it, and one whose route cannot be applied SHALL post the notice of WEBPUSH-005 rather than load the site on another route.

#### Scenario: The app is not running

- **GIVEN** WebSpace was swiped away from Recents and site A is allowed
- **WHEN** A's server pushes a message
- **THEN** the app's background engine starts, A's handler runs, its notification is posted, and the engine stops
- **AND** no foreground service was started

### Requirement: WEBPUSH-007 - Revoking unregisters and forgets

A site's notification settings SHALL show, while it is allowed, the push server it was allowed for and a way to revoke. Revoking, turning the site's notifications off, deleting the site, turning Web Push off and picking another distributor SHALL each unregister the site's registration and delete its keys, so that its endpoint stops delivering and its page's `getSubscription()` resolves to null. A page's own `PushSubscription.unsubscribe()` SHALL do the same for its site.

#### Scenario: The user revokes

- **GIVEN** site A is allowed
- **WHEN** the user revokes it in A's settings
- **THEN** A's registration is gone, its keys are deleted, and `getSubscription()` resolves to null

#### Scenario: Another distributor

- **GIVEN** sites A and B are allowed through distributor X
- **WHEN** the user picks distributor Y
- **THEN** A and B are unregistered from X, and each is asked again before it is given an endpoint through Y

### Requirement: WEBPUSH-008 - No grant, endpoint or key leaves the device

A site's grant, endpoint and keys SHALL NOT appear in a settings backup, a site's QR share or a log line kept outside developer mode's sensitive lines. A restored backup SHALL start every site unasked. The keys SHALL be kept at rest as the app keeps secrets, in its keychain-backed store.

#### Scenario: A backup

- **GIVEN** site A is allowed
- **WHEN** the user exports settings
- **THEN** the export contains neither A's endpoint, its keys nor that it was allowed
