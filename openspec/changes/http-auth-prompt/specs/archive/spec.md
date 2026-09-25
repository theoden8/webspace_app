## MODIFIED Requirements

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
| `cameraMode` (web camera access) | effectively `block` | `effectiveCameraMode` denies without prompting: the Block/Use-file/Allow popup, the file picker, and Android's OS permission dialog are OS-level UI, and a real grant lights the system camera indicator. Stored mode and any picked `virtualCameraSource` preserved for when the site leaves the archive. See [web-camera-access](../../../../specs/web-camera-access/spec.md) CAM-006. |
| Cookie persistence in the legacy engine | never written | `CookieIsolationEngine` reads `effectiveIncognito`, not the raw `incognito` field, at every guard. The raw field made an archive site's non-Secure cookies land in plaintext SharedPreferences (`cookies_fallback`) keyed by its cleartext `siteId` — underneath `_saveWebViewModels`'s `!isArchiveTier` filter, and a direct ARCH-001 break. See [per-site-cookie-isolation](../../../../specs/per-site-cookie-isolation/spec.md) ISO-005. |
| Tor exit-country pin | uses a kept GeoIP table, never downloads one | The table a pin needs (TOR-014) is a file outside the archive's keyspace; downloaded for an archived site alone, its presence and timestamp would say one pinned a country. `SiteUnloadEngine.torExitPinIsArchiveOnly` decides it. With no table kept, the pin fails closed (`exitCountryData`) rather than being dropped, since dropping it would route the site through a country it did not ask for. |
| Saved sign-ins (HTTP authentication) | never read or saved | `HttpAuthSecureStorage` keys by `siteId` in app-tier secure storage. `effectiveHttpAuthMemory` is `off`, so the sign-in prompt still works for the session but offers no Remember and reads nothing; the Saved sign-ins row is hidden. See [http-auth-prompt](../http-auth-prompt/spec.md) HTTPAUTH-004. |
| Nested webviews (`InAppWebViewScreen`) | inherit the effective values | The two `launchUrlFunc` call sites pass `effectiveNotificationsEnabled` / `effectiveCameraMode` / `effectiveMicrophoneMode` / `effectiveProtectedContentAllowed` / `effectiveIncognito`, not the stored fields. Passing a raw value let an archive site post OS notifications naming itself from a nested webview, and those persist in the shade after the archive is closed. |
| Logging that mentions any per-`siteId` identifier | `LogSensitivity.sensitive` | The tier-aware [`LogService`](../../../lib/services/log_service.dart) routes sensitive entries to a memory-only ring; they never reach disk, `debugPrint`, exports, or `adb logcat` / Console.app. Any new log call that includes a `siteId`, container name, cookie hostname, URL, or page title MUST be tagged sensitive (audit per #354 already covers every existing call site in `lib/`). The archive runtime flow (`_materialiseArchive`, `_openArchive`, `_closeArchive`, `_moveSiteToArchive`, `_promptRestoreArchive`) adds no log calls at all — strongest possible posture. |

Adding any new per-site feature SHALL re-run this audit. The CLAUDE.md per-site checklist gains an explicit "archive-tier compatibility" item.

#### Scenario: Notifications disabled in archive sites

**Given** an archive is being opened and its plaintext webspace list includes a site whose stored `notificationsEnabled` is `true`
**When** the runtime constructs the `WebViewModel` for that site
**Then** the effective `notificationsEnabled` is `false`
**And** the JS Notification polyfill is not injected for that site
**And** the site is not added to the `BGAppRefreshTask` / `WorkManager` periodic refresh set
**And** the site does not enter `_loadedIndices` at startup

#### Scenario: Legacy cookie engine writes nothing for an archive site

**Given** the device has no container support, so `CookieIsolationEngine` is
the live engine
**And** an archive-tier site is loaded with a live session in the shared jar
**When** the user switches sites, triggering
`unloadSiteForDomainSwitch` / `restoreCookiesForSite`, or deletes a site,
triggering `preDeleteCookieCleanup`
**Then** `CookieSecureStorage.saveCookiesForSite` is never called with a
non-empty list for the archive site's `siteId`
**And** the app-tier cookie store has no entry keyed by that `siteId`
**And** an app-tier site loaded at the same time still round-trips its own
cookies normally

#### Scenario: Nested webview from an archive site posts no notifications

**Given** an archive-tier site whose stored `notificationsEnabled` is `true`
**When** it opens an outbound link in an `InAppWebViewScreen`
**Then** the nested `WebViewConfig.notificationsEnabled` is `false`
**And** the `webNotification` JavaScript handler is not registered, so
nothing reaches `NotificationService`

#### Scenario: Settings UI hides overridden controls for archive sites

**Given** the user is editing a site in an archive-tier webspace
**When** the per-site settings sheet renders
**Then** the controls for the fields in the override matrix are absent or disabled
**And** the subtitle for each absent control explains briefly ("not available for archived webspaces")
