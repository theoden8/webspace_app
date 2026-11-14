## MODIFIED Requirements

### Requirement: CONT-003 — Same-Base-Domain Sites Coexist

In profile mode, two sites that share a base domain SHALL be able to
load and run concurrently with fully isolated cookies, `localStorage`,
`IndexedDB`, ServiceWorkers, and HTTP cache.

#### Scenario: Two GitHub accounts loaded simultaneously

**Given** site A (`github.com/personal`) and site B (`github.com/work`)
  both exist
**And** profile mode is active
**When** the user activates site A and then site B without unloading A
**Then** site A is NOT unloaded (no `_unloadSiteForDomainSwitch` call)
**And** both sites are in `_sites.loaded`
**And** site A's session cookies are not visible to site B and vice
  versa
**And** site B logging out does not log site A out

#### Scenario: Switching back to a still-loaded sibling preserves session

**Given** sites A and B (above) are both loaded with active sessions
**When** the user switches from A to B and back to A
**Then** site A's session is intact — no re-login, no reload, no
  capture-nuke-restore cycle ran

#### Scenario: Sites stay loaded across webspace switches

**Given** profile mode is active
**And** site A is in webspace `Work` and site B is in webspace `Personal`
**And** both A and B have been loaded
**When** the user switches webspace from `Work` to `Personal`
**Then** site A is NOT unloaded (it remains in `_sites.loaded` and its
  webview stays in the IndexedStack), even though it isn't part of the
  newly-active webspace
**Because** the per-site container isolates A's state from B's, so
  keeping A resident is harmless and avoids the cost of re-creating
  the webview if the user switches back

The orchestration lives in
[`SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch`](../../../../../lib/services/site_unload_engine.dart),
which returns `{}` when `useContainers == true` and delegates to the
legacy `WebspaceSelectionEngine` otherwise. To prevent unbounded growth
under this policy, two backstops apply:

1. **LRU cap**
   ([`kMaxLoadedSites`](../../../../../lib/services/site_unload_engine.dart),
   currently 20), counted in live webviews: a site's active webview
   and each warm tab (TAB-002). Activation evicts least-recently-used
   webviews when adding the new one would exceed the cap, warm tabs
   first (TAB-024). The priority tiers then keep the active site
   (hard-protected) and active-webspace sites (soft-keep) loaded in
   preference to stale sites from other webspaces.
2. **OS memory pressure**
   (`WidgetsBindingObserver.didHaveMemoryPressure`). Each event
   promotes one site one lifecycle tier deeper through the activation
   table's pressure plan, which picks from
   [`ActivationTable.pressureResident`](../../../../../lib/controllers/activation_table.dart),
   else `pressureCleared` (see webview-pause-lifecycle). The OS controls the curve: if
   pressure persists, the callback fires again and the next site is
   picked. One-per-event matches
   the OS signaling cadence and avoids over-evicting on transient
   pressure (e.g. another foregrounded app spike). Mirrors
   Flutter's own `ImageCache` reactivity pattern.

#### Scenario: Memory pressure during re-activation does not strand state

**Given** profile mode is active
**And** site A is loaded but not the currently-active site
**When** the user activates A and the OS fires
  `didHaveMemoryPressure` between the version bump and the eventual
  webview resume
**Then** A is NOT picked as the eviction victim
**Because** `activate` records its target in
  `SiteRuntime.activating` (set in the try block, cleared in
  finally); `SiteRuntime.retentionPriority` ranks it `activating`,
  which no eviction takes, alongside the `active` current site. Without the in-flight
  guard, mid-activation eviction would dispose A's webview, leaving
  `activate` to call `resumeWebView()` on a null controller
  (no-op) — the IndexedStack would re-create a fresh webview on next
  paint, silently wiping the user's URL/scroll/session.

#### Scenario: Memory pressure during a double tap does not strand state

**Given** site A is loaded but not the currently-active site
**When** the user taps A twice before the first activation lands
**And** the OS fires `didHaveMemoryPressure` while the second is in flight
**Then** A is NOT picked as the eviction victim
**Because** `SiteRuntime.activating` records the `activationVersion` the
  activation began at with its target, and only that activation clears it:
  the superseded first tap, whose target is the same, leaves the second's
  marker in place.
