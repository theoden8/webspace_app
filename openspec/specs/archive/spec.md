# Webspace Archive

## Status

Implemented; manual hardware validation pending. All requirements
ARCH-001 through ARCH-009 are wired end-to-end:

- **ARCH-001 (active-state neutrality):** enforced by filtering on
  `WebViewModel.isArchiveTier` in `_saveWebViewModels`,
  `_syncShortcutSites`, and `_exportSettings`. Regression tests in
  `test/archive_neutrality_test.dart`.
- **ARCH-002 (passphrase KDF):** `ArchiveCrypto.deriveSalt` (HKDF) +
  `deriveKey` (Argon2id 64 MiB / t=3 / p=4 / 32 bytes).
- **ARCH-003 (fixed slot pool):** 16 slots × 128 KiB each in
  `flutter_secure_storage`; slot bytes = full AEAD wire size with
  length-prefixed plaintext padding.
- **ARCH-004 (open/close lifecycle):** `_openArchive` / `_createArchive`
  / `_closeArchive` / `_closeAllArchives` on `_WebSpacePageState`.
  In-memory key only; zeroed on close.
- **ARCH-005 (multi-archive concurrency):** per-handle slices in
  `_archiveSlices`; closing one leaves the others intact.
- **ARCH-006 (per-site override matrix):** `effectiveNotificationsEnabled`
  / `effectiveLocalCdnEnabled` getters; home-shortcut menu hides for
  archive-tier sites; persistence and iOS App Intents shortcut sync
  filter on `isArchiveTier`.
- **ARCH-007 (opaque container ids):** HMAC-derived
  `archiveContainerId` plumbed through `WebViewConfig`; teardown on
  close via `ContainerNative.deleteContainer`.
- **ARCH-008 (settings entry point):** Restore archive / Close all
  archives tiles in the Data section of `AppSettingsScreen`; per-site
  "Close archive" item in the site context menu.
- **ARCH-009 (background snapshot mask):** `_maskBackground` overlay
  paints over the running tree on `inactive` / `paused` / `hidden` when
  at least one archive is open.

**Archive-tier collections:** an open archive's named collections are
materialised into `_webspaces` (marked `isArchiveTier`, a runtime-only
flag) so a restored archive keeps its grouping. `_saveWebspaces`
filters on the flag so they never enter app-tier SharedPreferences;
their membership rides the archive's own encrypted state and is
re-captured on close. Reopening restores the grouping; closing falls
back to the "All" view if the user was inside an archive collection.

**Deferred from v1:**

- **ARCH-010 (export tick):** exports remain app-tier-only with no
  opt-in switch. Adding the tick later is additive and won't break the
  existing on-device invariant.

## Purpose

Webspaces accumulate over time. Users who keep collections for occasional use — old projects, dormant accounts, research that comes and goes — end up with a cluttered switcher and an ever-growing active footprint. Archiving lets a webspace be set aside until needed and restored with a passphrase. The feature is gated such that the active app state is unaffected when no archives are restored; automated tests assert this invariant so regressions stay easy to bisect and users who never touch the feature see no change in behavior.

## Problem Statement

The current model assumes every webspace is live:

- Every webspace is enumerated in the switcher.
- Every site under every webspace contributes to startup index loading and lazy-loading priority.
- Every per-site cookie jar lives in the active [`cookie_secure_storage`](../cookie-secure-storage/spec.md) namespace, keyed by `siteId`.
- Every site's HTML cache, container directory, icon cache, etc. lives on disk indefinitely.

For a user who maintains webspaces they touch once a quarter — dormant accounts, archived projects, one-off research — this is constant overhead on a feature they rarely use. The user-facing fix would be "let me put a webspace away and bring it back when I need it," with an extra password gate so the put-away content carries the same secure-at-rest property as the rest of the secure-storage cookies.

This spec adds an archive feature that satisfies both. Crucially, when no archive has been restored in the current process, the app behaves *byte-identically* to a build without the feature — a property we assert with automated regression tests so the feature stays easy to bisect.

## Solution

### User-facing model

- The user creates an archive by typing a passphrase into the existing settings-backup / restore screen. If the passphrase doesn't match any existing archive, the UI offers to create a fresh one.
- The user opens an archive by typing its passphrase into the same screen. Webspaces and sites in that archive appear in the switcher alongside the user's regular webspaces.
- The user closes an archive by long-pressing one of its webspaces ("Close this archive") or by using "Close all archives" in settings. Closing flushes any cookie changes back to the encrypted store and tears down the archive's per-site containers.
- Multiple archives can be open at once. Each is independent.
- Archives auto-close on process exit (cold launch, force-stop, OS-killed-under-memory-pressure, reboot). Within a running process, an archive stays open until the user closes it explicitly.

### Internal model

- An *archive key* `MK_arch` is derived from the user's passphrase via Argon2id. The same passphrase always produces the same key — the passphrase **is** the archive's identity.
- All archive state — webspace list, per-site `WebViewModel` JSON, cookies — is packed into a single ciphertext entry per archive in `flutter_secure_storage`, encrypted under `MK_arch` with AES-256-GCM.
- The ciphertext entry lives in one of a fixed pool of K slots allocated at first launch. Slots are indistinguishable from random when unpopulated; slot count is constant regardless of how many archives exist. Restoration scans the pool, trial-decrypting each slot with the candidate key.
- Per-site features that touch disk, background scheduling, or OS-level UI are disabled or forced for archive-tier sites (notifications, home-shortcuts, LocalCDN, file-import-sites, authenticated proxies). Incognito mode is forced on so localStorage / IndexedDB / ServiceWorker state stays inside the container and doesn't persist beyond a session.
- Per-site containers for archive-tier sites use opaque, key-derived identifiers and are torn down on archive close. Cookies survive across sessions via the archive's ciphertext entry; container-internal state (localStorage, IndexedDB, ServiceWorkers, HTTP cache) does not.

## Requirements

### Requirement: ARCH-001 — Active state neutrality

The active app state SHALL be byte-identical regardless of whether the device has zero or N archives where all are closed. No counter, flag, version, salt, MRU entry, or feature-touched marker may vary with archive presence or count.

#### Scenario: SharedPreferences unchanged after archive create/open/close cycle

**Given** a fresh app install with no archives
**And** a snapshot of the SharedPreferences XML on disk after first launch
**When** the user creates an archive, adds a site to it, closes it, reopens it, and closes it again
**Then** the SharedPreferences XML on disk equals the snapshot byte-for-byte
**And** the `kExportedAppPrefs` registry contains no archive-related key

#### Scenario: app-tier WebViewModel collection unchanged

**Given** a process with M app-tier sites in `_webViewModels`
**When** the user opens an archive, switches between its sites, and closes the archive
**Then** `_webViewModels.length == M` before and after
**And** `_loadedIndices` for app-tier indices is unchanged
**And** the selected app-tier index and `_selectedWebspaceId` are unchanged

#### Scenario: settings-backup export bytes equal across archive operations

**Given** an export of the current settings produced via `SettingsBackupService.exportToJson(...)`
**When** the user opens an archive, performs operations on it, closes it
**And** re-runs `SettingsBackupService.exportToJson(...)` with the same `exportedAt` timestamp pinned
**Then** the two JSON strings are equal

#### Scenario: feature gate not used yields baseline behavior

**Given** an app process where no archive has been created and no passphrase has been entered
**When** the app runs normally through startup, site activation, settings, export, import
**Then** every code path that touches `ArchiveStorage` returns early as a no-op
**And** no `flutter_secure_storage` write occurs that wouldn't have occurred on a build without the feature, except for the one-time slot-pool initialization on first launch

### Requirement: ARCH-002 — Passphrase-based key derivation

Archive keys SHALL be derived from the user's passphrase via Argon2id, deterministically — the same passphrase produces the same key. No salt, key, or key-derivation parameter is persisted to disk in plaintext.

#### Scenario: Derivation parameters are explicit and stable

**Given** the archive key derivation service
**When** a key is derived from passphrase P
**Then** the salt is `HKDF-SHA256(P, info: "archive-salt-v1", L: 16)`
**And** the key is `Argon2id(password: P, salt: salt, m: 64MiB, t: 3, p: 4, hashLen: 32)`
**And** the derivation completes in roughly 0.5–2 seconds on target hardware
**And** the parameters are constants in `ArchiveKeyDerivation`, not configurable at runtime

#### Scenario: Same passphrase yields same key across devices

**Given** two devices running the same app build
**When** each derives a key from the same passphrase P
**Then** both devices produce the same 32-byte `MK_arch`

#### Scenario: Key material lives only in memory

**Given** an archive has been opened
**When** the archive is closed (explicitly, via process exit, or via OS-kill)
**Then** the `Uint8List` holding `MK_arch` is zero-filled before being released
**And** no `MK_arch` byte is ever written to disk
**And** the passphrase string is dropped from the dialog state without being stored

### Requirement: ARCH-003 — Fixed slot pool storage

Archive state SHALL be stored in a fixed pool of `K = 16` slots in `flutter_secure_storage`. The pool is allocated on first launch and never grows or shrinks. Slot entry names are constants in code, not key-derived; slot value bodies are AEAD ciphertext, padded to a uniform size when unpopulated.

#### Scenario: Pool initialized on first launch

**Given** a fresh app install
**When** the app reaches the post-startup point where the slot pool is checked
**Then** if any of the K slot entries is missing, all K are written with random bytes of the fixed slot size
**And** the missing-entry check is idempotent — subsequent launches do not rewrite existing slots

#### Scenario: Slot size constant

**Given** the slot pool
**When** any slot is read
**Then** its byte length is exactly the configured slot size constant (whether the slot holds an archive or random padding)

#### Scenario: Trial decryption resolves an archive

**Given** archive A occupies one of the K slots, encrypted under `MK_A`
**When** the user enters a passphrase that derives to `MK_A`
**Then** the open routine reads each slot in order, attempts `AES-256-GCM-decrypt(slot_bytes[head], key=MK_A, nonce=slot_bytes[12:24], AAD=slot_index_bytes)` for each
**And** the slot whose GCM tag verifies yields the archive plaintext
**And** all other slots fail GCM verification and are skipped silently

#### Scenario: Wrong passphrase yields no archive

**Given** no archive on the device is encrypted under the candidate key
**When** the user enters a passphrase whose derived key matches no slot
**Then** every slot fails GCM verification
**And** the open routine returns "no archive found"
**And** no UI distinguishes this response from "archive opened, contents empty" beyond the resulting state visible in the switcher

#### Scenario: Create when no archive exists for this passphrase

**Given** a passphrase whose derived key matches no slot in the pool
**When** the user confirms "create new archive with this passphrase"
**Then** a random slot among those that did not decrypt is overwritten with the new archive's ciphertext
**And** the previous random padding in that slot is irrecoverable

### Requirement: ARCH-004 — Open/close lifecycle

The archive open/close lifecycle SHALL keep `MK_arch` in memory only, persisting it for the lifetime of the running process unless explicitly closed.

#### Scenario: Stay open across backgrounding

**Given** an archive is open
**When** the app is backgrounded and resumed within the same process
**Then** the archive remains open
**And** the user is not re-prompted for the passphrase

#### Scenario: Close on explicit user action

**Given** an archive is open with sites loaded
**When** the user invokes "Close this archive" on any of its sites or "Close all archives" from settings
**Then** any pending cookie changes for that archive are flushed back to its ciphertext slot
**And** the archive's per-site containers are torn down via `ContainerNative.deleteContainer`
**And** the archive's `WebViewModel` instances are dropped from the runtime
**And** `MK_arch` is zero-filled in memory
**And** the switcher no longer shows the archive's webspaces

#### Scenario: Close on process exit

**Given** an archive is open
**When** the process exits (cold-launch the app again, force-stop, OS-kills under memory pressure, device reboots)
**Then** on next launch the archive is closed (the only way to reopen is to enter the passphrase again)
**And** any cookie changes that were not flushed before the exit are lost — flushes happen on close, on explicit save points, and on app-pause

### Requirement: ARCH-005 — Multi-archive concurrency

The system SHALL allow any number of archives to be open at the same time, each independent.

#### Scenario: Open second archive while first remains open

**Given** archive A is open
**When** the user enters a passphrase that opens archive B
**Then** archive B's webspaces appear in the switcher alongside archive A's and the app-tier webspaces
**And** archive A's state is unchanged

#### Scenario: Closing one archive does not affect the other

**Given** archives A and B are open
**When** the user closes archive A
**Then** archive A's webspaces and sites are removed from the runtime
**And** archive B's webspaces and sites remain in the switcher and continue to function
**And** `MK_B` is unaffected

#### Scenario: Independent ciphertext

**Given** archives A and B both occupy slots in the pool
**When** the user updates a site in archive A and closes it
**Then** only A's slot is overwritten
**And** B's slot bytes are unchanged

### Requirement: ARCH-006 — Per-site feature overrides for archive-tier sites

For sites in archive-tier webspaces, per-site features that touch disk, background scheduling, OS-level UI, or per-`siteId` entries outside the archive's MK keyspace SHALL be forced off or routed through the archive's key. The forced overrides are enforced at `WebViewModel` construction and are not user-configurable for archive sites.

The override matrix:

| Field | Archive-tier value | Reason |
|---|---|---|
| `notificationsEnabled` | always `false` | Notif sites auto-load at startup, register in iOS `BGAppRefreshTask` / Android `WorkManager`, prioritized in `SiteRetentionPriority` — all observable beyond archive state. |
| `localCdnEnabled` | always `false` | Per-site CDN cache writes site-correlated files to disk. |
| `incognito` | always `true` | Forces per-session localStorage / IndexedDB / ServiceWorker / HTTP-cache scope inside the container; nothing survives a session beyond cookies. |
| Home-shortcut action | unavailable | Pinning to launcher writes a system-level shortcut visible in launcher state. |
| File-imported sites | unavailable | `HtmlCacheService` lands HTML in the app-tier encrypted store keyed by app-tier paths. |
| Per-site authenticated proxies | password not persisted | `ProxyPasswordSecureStorage` keys by `siteId` in app-tier secure storage; unauthenticated (host/port-only) proxies are fine. |
| Auto-load at startup | never | Archive `siteId`s never enter `_loadedIndices` at startup regardless of any per-site flag — loading happens only after archive open. |
| Tracking-protection's LocalCDN sub-component | silently no-op | The umbrella ETP feature still applies (ClearURLs, DNS, content blocker, fingerprinting shim — all runtime-only); only the LocalCDN sub-component is skipped. |
| HTML cache (`HtmlCacheService.saveHtml` / `getHtmlSync`) | disabled | The cache file path is keyed by `siteId`; even though the bytes are AES-encrypted, the file's existence correlates to specific archive sites on disk inspection. Gated by `effectiveHtmlCachingEnabled` (false for archive-tier) in the `onHtmlLoaded` / `shouldFetchHtml` / `initialHtml` paths in `lib/main.dart`. Archive sites always load live from URL; first paint is slightly slower but on-disk footprint stays empty. |
| Webview navigation state (`SecureWebViewStateStorage.saveState` / `loadState`) | disabled | Same shape as HTML cache: per-`siteId` encrypted file containing `controller.saveState()` bytes (back/forward URL stack, Apple form data). Gated by an explicit `isArchiveTier` check in `_captureStateBytes` and the load path in `_setCurrentIndex`. Archive sites lose the in-process back/forward stack on memory-pressure eviction; acceptable trade for not leaking the URL stack to disk. `_closeArchive` calls `removeState(siteId)` for every owned site as a defensive back-erasure pass — covers any pre-fix bytes plus future code paths that forget the gate. |
| Logging that mentions any per-`siteId` identifier | `LogSensitivity.sensitive` | The tier-aware [`LogService`](../../../lib/services/log_service.dart) routes sensitive entries to a memory-only ring; they never reach disk, `debugPrint`, exports, or `adb logcat` / Console.app. Any new log call that includes a `siteId`, container name, cookie hostname, URL, or page title MUST be tagged sensitive (audit per #354 already covers every existing call site in `lib/`). The archive runtime flow (`_materialiseArchive`, `_openArchive`, `_closeArchive`, `_moveSiteToArchive`, `_promptRestoreArchive`) adds no log calls at all — strongest possible posture. |

Adding any new per-site feature SHALL re-run this audit. The CLAUDE.md per-site checklist gains an explicit "archive-tier compatibility" item.

#### Scenario: Notifications disabled in archive sites

**Given** an archive is being opened and its plaintext webspace list includes a site whose stored `notificationsEnabled` is `true`
**When** the runtime constructs the `WebViewModel` for that site
**Then** the effective `notificationsEnabled` is `false`
**And** the JS Notification polyfill is not injected for that site
**And** the site is not added to the `BGAppRefreshTask` / `WorkManager` periodic refresh set
**And** the site does not enter `_loadedIndices` at startup

#### Scenario: Settings UI hides overridden controls for archive sites

**Given** the user is editing a site in an archive-tier webspace
**When** the per-site settings sheet renders
**Then** the controls for the fields in the override matrix are absent or disabled
**And** the subtitle for each absent control explains briefly ("not available for archived webspaces")

### Requirement: ARCH-007 — Container lifecycle for archive-tier sites

For archive-tier sites on container-capable platforms, per-site containers SHALL use opaque, key-derived identifiers and SHALL be torn down on archive close. The archive feature is unavailable on platforms without container support.

#### Scenario: Opaque container id for archive sites

**Given** an archive site with stored `siteId = S`
**And** the archive is open with key `MK_arch`
**When** the container is created for that site
**Then** the container name is `ws-<X>` where `X = HMAC-SHA256(MK_arch, "container:" + S)` truncated and re-encoded to match the radix-36 / dash / radix-36 shape of an app-tier `siteId`
**And** the radix-36 string lengths fall within the same range as the app-tier siteId distribution

#### Scenario: Container torn down on archive close

**Given** archive A is open and has containers `C_1, C_2, ... C_n`
**When** the archive is closed
**Then** for each `C_i`, `ContainerNative.deleteContainer(C_i)` is called
**And** no on-disk container directory survives the close (best-effort — see Limitations)

#### Scenario: Cookies survive across archive sessions

**Given** the user logs in to site S in archive A and closes the archive
**When** the user reopens archive A in a later session
**Then** the cookies the user obtained during the previous session are present in S's freshly-recreated container
**Because** cookies were flushed to the archive's ciphertext slot on close and rehydrated into the container on open via the existing `cookie_secure_storage` capture-restore API

#### Scenario: Feature unavailable when containers are not supported

**Given** the runtime check `ContainerNative.isSupported() == false`
**When** the user opens the settings screen
**Then** the archive entry point is disabled with a subtitle explaining the platform requirement

### Requirement: ARCH-008 — Settings UI entry point

The user-facing entry point for archive restore and create SHALL live inside the existing settings-backup / restore section. It SHALL NOT be a separate "Archives" UI surface, and SHALL be visible identically regardless of whether the user has any archives.

#### Scenario: Entry point co-located with restore

**Given** the user opens the settings screen and navigates to settings-backup
**When** they reach the restore section
**Then** they see one combined "Restore" action that, when tapped, prompts for an optional file picker AND a passphrase field

#### Scenario: Passphrase opens an existing archive

**Given** the user enters a passphrase whose derived key matches an archive slot
**When** they confirm without selecting a file
**Then** the archive opens and its webspaces become visible in the switcher

#### Scenario: Passphrase with no match offers to create

**Given** the user enters a passphrase that matches no archive slot
**When** they confirm without selecting a file
**Then** the dialog offers "No matching archive found — create a new archive with this passphrase?"
**And** confirming creates the archive (occupying a random unused slot)
**And** declining returns to the restore screen with no change

#### Scenario: Close-this-archive action visible only on archive sites

**Given** the user opens the long-press / context menu on a webspace
**When** the webspace belongs to an open archive
**Then** the menu includes "Close this archive"
**And** when the webspace belongs to the app-tier, the menu does not include this item

#### Scenario: Close-all-archives action

**Given** the user opens the settings-backup section
**When** at least one archive is open
**Then** a "Close all archives" action is visible
**And** when no archive is open, the action is absent — its absence does not indicate anything about whether archives exist, because the action is purely about state in the running process

### Requirement: ARCH-009 — Background snapshot masking

When at least one archive is open and the app is backgrounded, the visible UI SHALL be masked to the app-tier slice before the OS snapshots the app for the task switcher / recents preview.

#### Scenario: iOS task switcher does not show archive sites

**Given** an archive is open and an archive site is the currently displayed view
**When** `applicationWillResignActive` fires
**Then** the IndexedStack switches to an app-tier index
**And** the masked view is what the OS captures for the task switcher preview
**And** on `applicationDidBecomeActive` the IndexedStack restores the archive-tier view

#### Scenario: Android recents does not show archive sites

**Given** the same setup on Android
**When** `onPause` fires
**Then** the UI mask runs before the system captures the recents thumbnail

### Requirement: ARCH-010 — Settings export/import never includes archives without explicit opt-in

`SettingsBackupService.createBackup` / `exportToJson` SHALL operate exclusively on the app-tier `_webViewModels` and `kExportedAppPrefs`. Archive-tier state is not included in exports by default. A user-controlled "include open archives" tick on the export dialog MAY add archive blobs to the export file at the user's explicit request; the resulting file's archive section is itself encrypted under each included archive's `MK_arch`.

#### Scenario: Default export excludes archives entirely

**Given** an archive is open with sites
**When** the user exports settings without ticking "include open archives"
**Then** the export JSON contains only app-tier sites, app-tier webspaces, and `kExportedAppPrefs`
**And** the export bytes are equal to the bytes a user without any archives would produce with identical app-tier state

#### Scenario: Default import targets only app-tier

**Given** the user imports a backup JSON
**When** the import flow runs
**Then** the restored webspaces and sites enter `_webViewModels` (app-tier)
**And** no archive is created or opened by the import flow

#### Scenario: V1 scope note

**Given** the v1 implementation
**When** the user is on the export dialog
**Then** the "include open archives" tick MAY be absent in v1 — the export remains app-tier-only.
**Note:** v1 ships export/import as app-tier-only; the tick is deferred to a follow-up. The byte-identity invariant in ARCH-001 makes adding the tick later additive, not breaking.

## Implementation Details

### Crypto primitives

A new dependency, [`cryptography`](https://pub.dev/packages/cryptography), provides Argon2id, HKDF, HMAC-SHA-256, and AES-256-GCM. The package is pure-Dart, has no native FFI, and works on every target platform.

Wrappers live in `lib/services/archive_crypto.dart` and expose only what the archive service needs:

```dart
class ArchiveCrypto {
  static Future<Uint8List> deriveSalt(String passphrase);
  static Future<Uint8List> deriveKey(String passphrase, Uint8List salt);
  static Future<Uint8List> hmacName(Uint8List key, String label);
  static Future<Uint8List> seal(Uint8List key, Uint8List plaintext, Uint8List aad);
  static Future<Uint8List?> open(Uint8List key, Uint8List ciphertext, Uint8List aad);
  static void zeroize(Uint8List key);
}
```

`seal` returns `nonce || ciphertext || tag`; `open` validates the tag and returns null on failure (i.e. wrong key) without throwing — the open routine relies on a null return to discriminate between "this slot is for someone else" and "this slot decrypted, the archive is found".

### Key derivation

`lib/services/archive_key_derivation.dart` is a thin wrapper around `ArchiveCrypto.deriveSalt + deriveKey`. The salt domain string is the constant `"archive-salt-v1"`. Argon2id parameters: memory 64 MiB, time 3 iterations, parallelism 4, output 32 bytes. These constants are not user-configurable.

### Slot pool

`lib/services/archive_storage.dart` owns the K slots in `flutter_secure_storage`. Slot count `K = 16`. Slot size `S = 256 KiB` (covers a typical archive — webspace list + cookies for ~50 sites — with comfortable headroom; oversize archives currently fail at write time, surfacing as a "this archive is too large" error to the user). Slot entry names are `ws_slot_00 ... ws_slot_15` — fixed constants.

Initialization on first launch writes `K` slots of `S` random bytes each. The check is idempotent: missing slots are filled; existing ones are not rewritten.

Open flow:
1. Read all K slots.
2. For each slot, attempt `ArchiveCrypto.open(MK, slot_bytes, aad: slot_index_bytes)`.
3. The first slot whose GCM verifies is the archive. Others are silently skipped.
4. If none verify, return "no archive."

Write flow (create or update):
1. If updating: write to the same slot the archive was loaded from.
2. If creating: pick a random slot whose bytes don't decrypt under `MK`, overwrite with the new ciphertext padded to `S`.

### Archive service

`lib/services/archive.dart` is the orchestrator. Public API:

```dart
class Archive {
  Future<OpenArchiveResult> open(String passphrase);
  Future<void> create(String passphrase, {String? initialWebspaceName});
  Future<void> close(ArchiveHandle handle);
  Future<void> closeAll();
  Future<void> save(ArchiveHandle handle);
  List<ArchiveHandle> get openArchives;
}
```

`ArchiveHandle` is an opaque token containing the in-memory `MK_arch` (`Uint8List`), the slot index it was loaded from, and the archive's plaintext state. The handle owns the lifetime of the key: on close, `ArchiveCrypto.zeroize(key)` runs before the handle is discarded.

### Runtime integration

`_WebSpacePageState` gains a separate `List<WebViewModel> _archiveWebViewModels` and `List<Webspace> _archiveWebspaces`. These are parallel to `_webViewModels` / `_webspaces` and never merged in persistence or export paths. The UI's switcher concatenates the two for display (app-tier first, archive-tier appended in archive-open order). When an archive closes, only its slice of the archive-tier collections is removed; the app-tier slice is byte-untouched (see ARCH-001).

The archive-tier flag is a single boolean on `WebViewModel` (`isArchiveTier`), defaulted to false and never serialized. It's set when the archive's plaintext is materialized into `WebViewModel` instances on open. The override matrix in ARCH-006 reads this flag in `WebViewModel.toWebViewConfig` (and in the per-site settings sheet builder) to clamp the per-site fields.

### Container lifecycle

`ContainerIsolationEngine` gains two methods:

- `Future<String> ensureArchiveContainer(WebViewModel site, Uint8List archiveKey)` — computes the opaque container id from `HMAC(archiveKey, "container:" + site.siteId)`, calls `getOrCreateContainer`, returns the id.
- `Future<void> tearDownArchiveContainers(Iterable<String> containerIds)` — calls `deleteContainer` on each.

The opaque id is formatted to match the app-tier siteId shape (radix-36 / dash / radix-36). The formatting helper is shared between the app-tier `_generateSiteId` and the archive opaque-id deriver — both produce strings of the same shape so a directory listing under `<XDG_DATA_HOME>/flutter_inappwebview/containers/` shows uniform-looking names.

### Cookie persistence

Archive cookies live in the archive's ciphertext slot, not in the app-tier `secure_cookies` entry. `CookieSecureStorage` gains an archive-aware variant that takes an archive key + slot index and reads/writes the archive's slot contents. The plaintext format inside the slot is the same JSON map shape used by app-tier `secure_cookies`, so the per-site loading code path is the same once the archive is decrypted.

App-tier `CookieSecureStorage` behavior is unchanged.

### Settings UI

The existing settings-backup section in `lib/screens/settings.dart` already exposes export and restore. The restore dialog grows a passphrase field and routes the entered passphrase through `Archive.open`. If a backup file was also selected, the import proceeds for app-tier; if not, the passphrase is the only input and the archive open / create flow runs.

The per-webspace long-press menu adds "Close this archive" when the webspace's home model has `isArchiveTier == true`. The settings-backup section adds "Close all archives" when `Archive.openArchives.isNotEmpty`.

### Background snapshot

`AppLifecycleListener` (already present in the app for the pause-lifecycle work) gains a callback that, on `inactive` / `paused`, switches the IndexedStack to an app-tier index when any archive is open. On `resumed`, the previous archive-tier index is restored from memory.

## Testing

### Active state neutrality

`test/archive_neutrality_test.dart` runs the following with an injected `FakeFlutterSecureStorage` + `MemoryArchiveStorage`:

- Initial SharedPreferences snapshot vs post-archive-cycle snapshot — assert byte-equal.
- `_webViewModels` length, `_loadedIndices`, `_selectedWebspaceId` before / after archive ops — assert equal.
- `SettingsBackupService.exportToJson` before / after archive ops with `exportedAt` pinned — assert byte-equal.
- A "feature-not-used" run (no passphrase ever entered) vs a "feature-used" run that opens and closes archives — assert app-tier state files identical.

These tests run in CI and are the regression-prevention spine of ARCH-001.

### Crypto correctness

`test/archive_crypto_test.dart`:

- KDF determinism: same passphrase, repeated derivation, yields the same 32-byte key.
- KDF independence: different passphrases yield independent keys (Hamming distance check on ~hash output).
- AEAD round-trip: `seal` then `open` returns the original plaintext with matching AAD.
- AEAD failure: tampered ciphertext, wrong AAD, or wrong key returns null from `open`.

### Slot pool

`test/archive_storage_test.dart`:

- First-launch initialization writes K slots of S bytes each.
- Trial-decrypt scans all slots and returns the right one.
- Trial-decrypt returns null when no slot matches.
- Create occupies a slot that didn't previously decrypt.
- Re-create with the same passphrase reuses the same slot.

### Lifecycle

`test/archive_test.dart`:

- Open / close cycle leaves `MK_arch` zeroized.
- Multiple archives open concurrently; closing one preserves the other.
- Process-exit simulation drops all archive state.

## Limitations

- **Best-effort deletion.** Flutter `flutter_secure_storage` and underlying OS-level secure stores do not guarantee bit-level erasure of overwritten or deleted entries. The same caveat applies to per-site container directory deletion — the underlying filesystem may retain freed blocks. Documented; not addressable at app layer.
- **Memory zeroization is best-effort.** Dart strings are immutable; the passphrase string can't be reliably zero-filled. We keep the passphrase as a `String` only for the brief moment between dialog submit and KDF call, then immediately drop it. The derived `MK_arch` is held in `Uint8List` and zero-filled on close.
- **Live-device forensics is out of scope.** An adversary executing code inside the running app process while an archive is open can read `MK_arch` and the archive's plaintext from memory. There is no software-only mitigation at the app layer.
- **Slot size cap.** Archives larger than 256 KiB of packed state (typically: cookies + webspace JSON for ~50 sites) currently fail at write with a clear error to the user. v1 does not split archives across slots.
- **Per-site browser state beyond cookies does not migrate on move-to-archive.** Cookies are captured from the running container and pushed into the new opaque container on next webview build. `localStorage`, `IndexedDB`, `ServiceWorker` registrations, and `HTTP cache` are not — the new container is a fresh slate. Sites that store user preferences (theme, language, layout) in `localStorage` will revert to defaults the first time they're opened from an archive after a move. The move-to-archive snackbar warns the user. Mitigation would require fork-side API to read/write per-container `localStorage`; tracked but out of scope for v1.
- **Dart-side console leakage is closed.** Every `LogService` call in `lib/` that interpolated a URL, host, site JSON, or stack trace is now `LogSensitivity.sensitive` (download / blob errors, share-intent failures, malformed-site-JSON boot warnings, proxy-apply failures), so it lands in the memory-only ring and never reaches disk / `debugPrint` / `adb logcat` / Console.app.
- **Native (fork) console leakage remains.** Re-audited against `v6.2.0-beta.3-privacy-v3` — still present, unchanged from the v1 audit:
  - `flutter_inappwebview_android/.../InAppBrowserManager.java:129` — `Log.d(LOG_TAG, url + " cannot be opened: ...")` (intent-launch failure path)
  - `flutter_inappwebview_android/.../InAppWebViewClient.java:131` — `Log.d(LOG_TAG, "Request '" + url + "' automatically allowed...")` (regexToAllowSyncUrlLoading match)
  - `flutter_inappwebview_ios/.../MyCookieManager.swift:211` and `flutter_inappwebview_macos/.../MyCookieManager.swift:207` — `print("Cannot get WebView cookies. No HOST found for URL: \(url)")`
  - Container, profile, and Linux per-session manager files are clean. WebSpace's own fork patches do not add new log calls.
  Fixing these requires a fork-side patch (annotated `[WebSpace fork patch]`) that redacts the URL or drops the log entirely, then a fork tag + `pubspec` ref bump — out of scope for an app-repo PR. Until then, the URLs of intent-launch failures, regex-allowlisted nested-load decisions, and the rare host-less cookie-read paths reach `adb logcat` / Console.app from any site.

## Files

### Created

- `lib/services/archive_crypto.dart` — Argon2id / HKDF / HMAC / AES-GCM wrappers
- `lib/services/archive_key_derivation.dart` — passphrase → `MK_arch` derivation
- `lib/services/archive_storage.dart` — fixed slot pool
- `lib/services/archive.dart` — orchestrator (open / create / close)
- `test/archive_crypto_test.dart`
- `test/archive_storage_test.dart`
- `test/archive_test.dart`
- `test/archive_neutrality_test.dart`
- `openspec/specs/archive/spec.md` — this specification

### Modified

- `pubspec.yaml` — adds `cryptography: ^2.7.0`
- `lib/web_view_model.dart` — `isArchiveTier` flag (runtime-only, never serialized) + override matrix in `toWebViewConfig`
- `lib/services/cookie_secure_storage.dart` — archive-aware variants
- `lib/services/container_isolation_engine.dart` — `ensureArchiveContainer` / `tearDownArchiveContainers`
- `lib/main.dart` — `_archiveWebViewModels` / `_archiveWebspaces` parallel collections, runtime integration, background-snapshot mask
- `lib/screens/settings.dart` — passphrase field in restore dialog, "Close all archives" action
- `CLAUDE.md` — adds the active-state-neutrality invariant and the per-site override audit rule
