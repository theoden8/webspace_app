# Incognito Mode

## Purpose

A per-site `incognito` toggle that produces a session ephemeral to the
process: nothing the site stores during a session — cookies,
localStorage, IndexedDB, ServiceWorker registrations, HTTP cache, the
last-visited URL, the last seen page title — survives an app restart.
Configuration the user typed (init URL, custom name, proxy, language,
location, etc.) does survive.

The toggle has two effects woven into otherwise-shared code paths:

1. **In-memory state stays available** while the app is alive, so a user
   can keep using the site through tab switches, webspace switches, and
   even an app-background → resume cycle.
2. **On serialization to disk** and **on app restart**, the site's
   session-scoped data is dropped so the next launch reads back nothing.

The legacy [per-site cookie isolation engine](../per-site-cookie-isolation/spec.md)
already exempts incognito sites from same-domain conflict resolution
(ISO-005). This spec is the broader contract those exemptions live
under.

## Status

- **Date**: 2026-05-04
- **Status**: Implemented

---

## Requirements

### Requirement: INC-001 - Cookies Are Not Captured

Cookies in the shared `CookieManager` SHALL NOT be captured to a site's
encrypted storage when that site is incognito.

#### Scenario: Incognito site unloads without writing cookies

**Given** an incognito site A is loaded and has accumulated session cookies in `CookieManager`
**When** site A is unloaded (webspace switch, LRU eviction, conflict resolution)
**Then** no cookies are written to A's siteId-keyed encrypted storage

#### Scenario: Incognito site is exempt from domain conflict

**Given** a regular site R and an incognito site I share the same base domain
**When** the user activates I
**Then** R remains loaded
**And** I loads without triggering R's capture-nuke-restore

---

### Requirement: INC-002 - Navigation State Is Not Persisted

The system SHALL NOT persist a webview's `saveState()` bytes (back/forward stack, scroll position, form data) for an incognito site.

#### Scenario: Incognito site is unloaded

**Given** an incognito site is loaded and the user has navigated several pages deep
**When** the site is unloaded (memory pressure, LRU, manual go-home)
**Then** no state bytes are written to encrypted state storage for the site's siteId

---

### Requirement: INC-003 - Session State Is Stripped On Serialization

When a `WebViewModel` is serialized (`toJson`), the system SHALL omit
fields that represent session state for incognito sites.

The session-scoped fields are: `currentUrl`, `pageTitle`, and
`cookies` (the in-memory list, distinct from the encrypted store).

#### Scenario: Incognito JSON omits currentUrl

**Given** an incognito `WebViewModel` whose `currentUrl` differs from `initUrl`
**When** `toJson()` is called
**Then** the resulting map does NOT contain a `currentUrl` key
**And** does NOT contain a `pageTitle` key
**And** the `cookies` list is empty regardless of the in-memory list

#### Scenario: Non-incognito JSON retains session state

**Given** a non-incognito `WebViewModel` with `currentUrl != initUrl` and a non-empty cookie list
**When** `toJson()` is called
**Then** `currentUrl` is present
**And** `pageTitle` is present (may be null)
**And** `cookies` reflects the in-memory list

---

### Requirement: INC-004 - Session State Is Discarded On Deserialization

When a `WebViewModel` is rehydrated from JSON (`fromJson`), the system
SHALL discard any persisted session state if `incognito = true`. This
covers JSON written by older builds (defense in depth) and JSON copied
between devices.

#### Scenario: Legacy JSON with incognito + currentUrl

**Given** a JSON map written by an older build with `incognito: true` and `currentUrl: "https://maps.google.com/maps/@40.7,-74.0,15z"`
**When** `WebViewModel.fromJson(json, ...)` is called
**Then** the resulting model's `currentUrl` equals its `initUrl`
**And** the resulting model's `cookies` list is empty
**And** the resulting model's `pageTitle` is null

---

### Requirement: INC-005 - Container On-Disk Data Is Wiped On Startup

On the platforms where per-site native containers are used (see
[per-site-containers](../per-site-containers/spec.md)), each
container persists localStorage, IndexedDB, ServiceWorkers, and HTTP
cache to disk. The system SHALL delete every incognito site's container
during app startup, before any webview binds. The container is
recreated empty on the next bind.

> **Why a wipe step is needed on top of `incognito = true`.** The fork
> makes `incognito = true` ephemeral on Apple (`WKWebsiteDataStore.nonPersistent()`)
> and Linux (`webkit_network_session_new_ephemeral()`) by skipping the
> container bind entirely on those platforms. On **Android System
> WebView**, `setIncognito(true)` only clears the global `CookieManager`
> and `WebSettings.setSavePassword/SaveFormData(false)` — the
> `androidx.webkit.Profile` bound to the container keeps writing
> localStorage / IndexedDB / cache / cookies to disk. Without an
> explicit wipe, an Android incognito session leaks across app
> restarts. The wipe is a no-op on platforms where the container was
> never materialized, which preserves correctness without branching.

#### Scenario: Incognito container is wiped on startup

**Given** the previous app session left disk artifacts in the container `ws-<siteId>` for an incognito site (localStorage, IDB rows, cached resources)
**When** the app starts and `_restoreAppState` runs
**Then** `ContainerIsolationEngine.wipeContainers([siteId])` runs before any site activation
**And** the on-disk container is deleted

#### Scenario: Wipe is platform-aware no-op

**Given** the running platform does not support the Container API (Windows, web, Android System WebView <110, iOS <17, macOS <14, WPE WebKit <2.40)
**When** `wipeContainers([...])` runs
**Then** it returns 0 without error

#### Scenario: Non-incognito containers are preserved

**Given** the user has a mix of incognito and non-incognito sites
**When** `_restoreAppState` runs
**Then** only the incognito sites' containers are deleted
**And** non-incognito sites' containers (with their localStorage / IDB / cookies / SW / cache) are intact

---

### Requirement: INC-006 - Encrypted Per-Site Storage Treats Incognito As Orphan

The startup garbage-collection passes for session-scoped per-site
stores SHALL treat incognito siteIds as orphaned, sweeping their
entries even though the site itself is alive. This handles users who
toggled an existing site to incognito after data accumulated.

The session-scoped stores are: `CookieSecureStorage`,
`HtmlCacheService`, and `WebViewStateStorage`.

The non-session stores (`ProxyPasswordSecureStorage`,
`HtmlImportStorage` for file:// imports) MUST be excluded from this
treatment — they hold user configuration, not session data.

#### Scenario: Pre-toggle cookies are swept

**Given** site A had cookies stored under its siteId in encrypted storage
**And** the user has now toggled A to incognito
**When** the app starts
**Then** A's cookie entry is removed by the orphan sweep
**And** A's proxy password (if any) and imported HTML (if any) remain

#### Scenario: Pre-toggle navigation state is swept

**Given** site A had a saved `interactionState` blob under its siteId
**And** the user has now toggled A to incognito
**When** the app starts
**Then** A's state blob is removed by the orphan sweep

---

### Requirement: INC-007 - In-Memory State Survives App Lifecycle

While the process is alive, an incognito site SHALL behave like any
other site for the purpose of tab switches, webspace switches, and the
foreground/background lifecycle. The "ephemeral" contract applies only
across **process death** (app kill, OS-killed-while-backgrounded,
forced restart).

#### Scenario: Incognito state preserved across webspace switch

**Given** an incognito site has navigated several pages deep
**When** the user switches to another webspace and back
**Then** the incognito site is at the same URL
**And** its in-memory cookies / localStorage are intact (within the live native session)

#### Scenario: Incognito state preserved across app background-resume

**Given** an incognito site is loaded
**When** the user backgrounds the app and returns within the OS retention window
**Then** the site is at the same URL
**And** the page state has not been wiped

#### Scenario: Incognito state lost on app kill

**Given** an incognito site has navigated to a deep URL and accumulated localStorage entries
**When** the user force-kills the app and relaunches
**Then** the site loads at its `initUrl`, not the deep URL
**And** localStorage is empty
**And** cookies are empty
