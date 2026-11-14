## MODIFIED Requirements

### Requirement: PAUSE-006 — Cascading Memory-Pressure Lifecycle

When the OS signals memory pressure via `WidgetsBindingObserver.didHaveMemoryPressure` while the app is resumed (PAUSE-034), the system SHALL promote one live webview by one tier per event, cascading through three states from least to most aggressive: `resident` → `cacheCleared` → `savedForRestore`. A webview is a site's active webview or a warm tab's (TAB-002); a warm tab's webview reaching `savedForRestore` is disposed and parks the tab, its state already captured as it went warm (TAB-028).

The cascade is owned by [`SiteLifecyclePromotionEngine`](../../../../../lib/services/site_lifecycle_promotion_engine.dart), a pure-Dart picker that:

- Walks tiers from least to most aggressive (`resident` first, then `cacheCleared`).
- Within a tier, takes warm tabs before any active webview, in the order TAB-024 gives (warm tabs of other sites, hosted first, then warm tabs listed under the site on screen), then evicts out-of-active-webspace sites before in-webspace sites.
- Within a (tier, keep) bucket, picks the LRU oldest first.
- Never picks the active site (`SiteRuntime.current`) or the in-flight activation target (`SiteRuntime.activating`): `SiteRetentionPriority.evictable` is false for both, and every picker takes its candidates through [`evictionOrder`](../../../../../lib/services/site_retention_priority.dart), which leaves them out.
- Treats `savedForRestore` as terminal — those sites are no longer in `_sites.loaded`, but their state lives in [`WebViewStateStorage`](../../../../../lib/services/webview_state_storage.dart) keyed by `siteId`.

The OS controls the curve: if pressure persists, the callback fires again and the next victim is promoted. One-per-event matches the OS signaling cadence and avoids over-evicting on transient pressure (e.g. another app's foreground spike).

**Formal model:** the picker's selection invariants are model-checked in [formal/retention.tla](../../../../../formal/retention.tla): `Inv_CurrentKept` (the active site is never evicted) and `Inv_NotifLast` (higher-retention sites — e.g. notification sites in `SiteRetentionPriority` — are evicted only after every lower-retention non-active site is gone). The `starve` demonstrator evicts a retained site early and TLC rejects it. The model abstracts the per-site `resident → cacheCleared → savedForRestore` promotion as a binary loaded/evicted over one monotone pressure episode.

#### Scenario: First memory pressure event clears cache without losing state

**Given** the app has 5 loaded sites — one active and four backgrounded `resident`
**When** `didHaveMemoryPressure` fires for the first time
**Then** the LRU oldest non-active site is promoted from `resident` to `cacheCleared`
**And** `controller.clearCache()` is called on it (frees ~10-50 MB without disposing)
**And** the user's tab state, back/forward stack, and active site remain untouched

#### Scenario: Sustained pressure cascades all loaded sites through clearCache before disposing any

**Given** every loaded site is at the `resident` tier
**When** `didHaveMemoryPressure` fires N times in succession (where N is the number of non-active loaded sites)
**Then** every non-active loaded site reaches `cacheCleared` before any reaches `savedForRestore`
**Because** the picker walks tiers from lowest to highest — `resident` is exhausted first, regardless of LRU age within other tiers

#### Scenario: cacheCleared site disposes with state captured

**Given** every non-active loaded site is at `cacheCleared`
**When** `didHaveMemoryPressure` fires again
**Then** the LRU oldest cacheCleared site is promoted to `savedForRestore`
**And** `controller.saveState()` captures the navigation state to `WebViewStateStorage` keyed by siteId
**And** `disposeWebView()` tears down the webview (and in legacy mode, `CookieIsolationEngine.unloadSiteForDomainSwitch` captures cookies first)
**And** the site is removed from `_sites.loaded`
**Because** the cascade reaches its terminal tier — the renderer process is torn down (~100s MB freed); state is preserved for re-activation

#### Scenario: Re-activating a savedForRestore site rehydrates the back/forward stack

**Given** site A is in `savedForRestore` (disposed, but its bytes are in `WebViewStateStorage`)
**When** the user activates site A
**Then** `activate` reads the bytes from storage and queues them on the model via `tabBinding.queue`, tagged with the tab they were read for
**And** the model's `lifecycleState` is reset to `resident`
**And** the webview is rebuilt — `getWebView`'s `onControllerCreated` consumes the pending bytes and calls `controller.restoreState(bytes)`
**And** the back/forward stack is restored on every supported platform:
  - **Android** via `WebView.restoreState(Bundle)`
  - **iOS 15+ / macOS 12+** via `WKWebView.interactionState` (also restores form-field values + scroll)
  - **Linux** (WebKitGTK / WPE) via `webkit_web_view_restore_session_state`
**And** on iOS 15+ / macOS 12+ form-field values are restored too — Linux and Android only carry history + scroll

The load ordering differs by platform because the restore APIs differ. On iOS/macOS the `initialUrlRequest` (set to `currentUrl` on the model) kicks off a navigation that lands at the most-recent saved URL, and assigning `interactionState` replaces the back/forward stack **in place** — a brief redundant nav, acceptable for the much-better re-activation UX. On Android `WebView.restoreState` is silently dropped if the WebView has already navigated (its docs warn of "undesirable side-effects" when called after the view has built state), so the root webview is instead built with **no** initial load — `WebViewConfig.deferInitialLoad`, gated by the pure `deferInitialLoadForRestore(hasPendingRestoreState, isAndroid)`. restoreState then applies to a pristine history and `onControllerCreated` reloads the restored top entry, since Android does not restore display data. Live JS heap and DOM are not preserved on any platform — re-execution starts fresh.

#### Scenario: Android applies restoreState before any navigation

**Given** site A on Android has an http(s) `currentUrl` and nav-state bytes queued via `tabBinding.queue`
**When** the webview is rebuilt
**Then** it is constructed with no `initialUrlRequest` and no cached-HTML `initialData` (so the WebView has an empty back/forward list)
**And** `onControllerCreated` calls `controller.restoreState(bytes)` first
**And** on success it issues one `reload()` to materialize the restored current entry while preserving the back stack
**And** if `restoreState` reports failure it falls back to loading `currentUrl` so the view is never left blank

#### Scenario: Android file import is not deferred

**Given** site A on Android is a `file://` import (synthetic, non-fetchable URL) with nav-state bytes queued
**When** the webview is rebuilt
**Then** the initial load is NOT suppressed — it keeps rendering its cached `initialData`
**Because** the post-restore `reload()` would fail with ERR_FILE_NOT_FOUND and a static local page has no meaningful back/forward stack to restore

#### Scenario: Active webspace tier is preserved over stale workspace

**Given** the user is on webspace `Work` with sites {A, B, active=A} and webspace `Personal` has loaded site C
**When** `didHaveMemoryPressure` fires
**Then** site C (out-of-active-webspace) is promoted before site B (in-active-webspace) at every tier transition
**Because** within a tier, the picker orders by `SiteRetentionPriority`, which ranks the active webspace's sites (`webspace`) above other loaded sites (`loaded`), and exhausts the lower tier first

#### Scenario: Concurrent didHaveMemoryPressure events do not double-promote

**Given** a memory pressure event is mid-flight (capturing state, awaiting `saveState()`)
**When** the OS fires `didHaveMemoryPressure` again before the first handler completes
**Then** the second invocation drops out at the `_memoryPressureGuard` guard
**And** no site is double-promoted
**Because** the OS will fire again if pressure persists, and the next picker run sees the updated state map

#### Scenario: Memory pressure during re-activation does not strand state

**Given** site A is in `savedForRestore`
**And** the user has just activated A — `activate` is mid-flight, awaiting `_stateStorage.loadState`
**When** `didHaveMemoryPressure` fires
**Then** the picker excludes A from the candidate iteration
The handler applies the plan [`SiteUnloadEngine.plan`](../../../../../lib/services/site_unload_engine.dart) gives for `MemoryPressure`: a cache clear for a `resident` victim, an unload for a `cacheCleared` one. Every other residency decision (activation, a webspace switch, a settled Tor exit, a nested open, a slot's identity change) is a `ResidencyEvent` case of the same plan, applied by `SiteUnloadEngine.apply`, which follows each site by identity and skips one no longer loaded when its turn comes.

**Because** `activate` records its target in `SiteRuntime.activating` (set synchronously before any await), and `SiteRuntime.retentionPriority` ranks it `activating` alongside the `active` current site. Without the in-flight guard, mid-activation eviction would dispose A's about-to-be-built webview, leaving `restoreState` to no-op against a null controller.

#### Scenario: An eviction under way backs off from a site that starts activating

**Given** site A is loaded in the background and a memory-pressure event has picked it for unload
**And** the unload is capturing A's navigation state, or on the shared jar its cookies
**When** the user activates A before the capture returns
**Then** the unload does not dispose A and A stays loaded
**Because** an unload whose reason picks by retention priority (`UnloadReason.pickedByPriority`: memory pressure, the loaded-site cap) asks `priorityOf` again after its captures, with no await before the dispose, and backs off from a site that is no longer evictable. The pick alone cannot see an activation that begins after it. History: [BUG-033](../../../../../docs/bugs/033-eviction-disposes-the-activating-site.md).

#### Scenario: Pressure takes a warm tab before a background site

**Given** site A is on screen, site B is loaded in the background at `resident`, and site C in the background has a warm tab at `resident`
**When** `didHaveMemoryPressure` fires
**Then** C's warm tab is promoted to `cacheCleared`
**And** B is not touched
**Because** warm tabs rank below every active webview at each tier (TAB-024)
