# DNS Blocklist — per-site level delta

## ADDED Requirements

### Requirement: DNS-019 - Tiered Blocklist Storage

The downloaded blocklists SHALL be held as a partition: every domain sits in
the tier of the **lowest** severity level whose list names it. Tiers SHALL be
disjoint, so the total entry count equals the size of the largest downloaded
list rather than the sum of the lists.

"Blocked at level N" SHALL mean "the domain's tier is in 1..N". The partition
is what makes per-site levels free: the data is shared, and the per-site
setting is a comparison against the tier.

Tiers are built by [`DnsTiersBuilder`](../../../../../lib/services/dns_tier_engine.dart),
which is fed one domain at a time in ascending level order. A level's parsed
list SHALL NOT be materialised as a set alongside the tiers it is about to be
subtracted into — that is the one place the partition could cost more memory
than the flat set it replaces.

Each downloaded level SHALL be cached in its own file
(`dns_blocklist_<level>.txt`) and the set of downloaded levels persisted under
`dns_block_downloaded_levels`.

#### Scenario: A domain in several lists takes the lowest tier

**Given** `light.example` appears in the Light, Pro and Ultimate lists
**When** all three are downloaded
**Then** it sits in tier 1 and in no other tier
**And** the total entry count equals the Ultimate list's

#### Scenario: A level with no downloaded list has no tier

**Given** only the Pro list has been downloaded
**Then** `downloadedLevels` is `{3}`
**And** tiers 1, 2, 4 and 5 are empty

#### Scenario: The pre-tier cache is migrated

**Given** an install that cached one blocklist under `dns_blocklist.txt` at
level 3
**When** the app starts after upgrading
**Then** the file is re-filed as `dns_blocklist_3.txt`
**And** level 3 is recorded as downloaded
**And** the blocklist is available without a network request

---

### Requirement: DNS-020 - Per-Site Severity Level

Each site SHALL have a `dnsBlockLevel` setting (default `null`, meaning
"follow the app-wide level"). A site with a resolved level of N SHALL block
exactly the domains whose tier is in 1..N; level 0 blocks nothing.

The per-host decision cache SHALL store the host's tier, not a blocked or
allowed bit, so one cached answer serves every site whatever level it runs at.

The site's own toggle and its level SHALL be resolved into one number at the
call site (`WebViewConfig.effectiveDnsLevel`): 0 when the toggle is off,
otherwise the resolved level. Decision sites SHALL consult that number rather
than the toggle and the level separately.

#### Scenario: A site relaxes below the app-wide level

**Given** the app-wide level is Pro and the Light list is downloaded
**And** a site is set to Light
**When** the site requests a domain that only the Pro list names
**Then** the request is allowed
**And** the same domain is still blocked for every other site

#### Scenario: A site raises above the app-wide level

**Given** the app-wide level is Pro and the Ultimate list is downloaded
**And** a site is set to Ultimate
**When** the site requests a domain that only the Ultimate list names
**Then** the request is blocked
**And** it is allowed for sites on the app-wide level

#### Scenario: One host, several levels, one walk

**Given** two sites at different levels request the same host
**Then** the host's tier is computed once and cached
**And** each site's decision is that tier compared against its own level

#### Scenario: Stats record what the site actually did

**Given** a site whose DNS blocking is off navigates to a blocklisted domain
**Then** the navigation is allowed
**And** the request is recorded as allowed, not as a block

---

### Requirement: DNS-021 - On-Demand Level Download

Picking a per-site level whose list is not downloaded SHALL fetch that level's
list, through the same mirror sequence and body validation as the app-wide
download, and fold it into the partition. The app-wide download SHALL keep
fetching exactly one level, so an install that never uses a per-site level
downloads no more than before.

Until the list lands, a site level that is not in `downloadedLevels` SHALL
resolve to the app-wide level. Evaluating the requested level against a
partition that has no boundary at it would block nothing at all, which is the
one direction a relaxation must never take. Level 0 needs no list and SHALL
always resolve to itself.

A level no site asks for and that is not the app-wide level SHALL be dropped —
its file deleted and its tier freed — during the deferred startup sweep, and
not on the per-save path, where an unsaved edit would not yet name it.

#### Scenario: Picking an undownloaded level

**Given** a site is set to Light while only the Pro list is downloaded
**Then** the row reports the level is not downloaded and names the level in
use
**And** the site blocks at Pro until the Light list arrives
**And** the Light list is fetched

#### Scenario: A failed fetch leaves the site protected

**Given** every mirror fails for the requested level
**Then** the user is told the download failed
**And** the site keeps blocking at the app-wide level

#### Scenario: An abandoned level is reclaimed

**Given** the only site running at Light is moved back to the app-wide level
**When** the app next runs its deferred startup sweep
**Then** `dns_blocklist_1.txt` is deleted and tier 1 is freed

---

### Requirement: DNS-022 - Android Sub-Resources Honour the Site's Level

The native sub-resource interceptor SHALL evaluate each request at the level of
the site whose webview it is attached to. The blocklist it consults is
app-wide, so the level passed at attach time is the only place an Android
sub-resource learns the site's DNS posture.

The blob pushed to the native side SHALL carry the partition: a `#<level>`
marker line introduces each tier. A blob with no marker SHALL load as level 1
so an older payload still parses.

The interceptor's per-host cache SHALL hold tiers, so a level change moves the
site's decisions without invalidating the cache. An attach call that names no
level SHALL reuse the level last reported for that site rather than assuming
full strength.

#### Scenario: A site with DNS blocking off fetches a sub-resource

**Given** a site has the DNS blocklist switched off
**When** its page fetches a blocklisted sub-resource on Android
**Then** the request is allowed

#### Scenario: A site's level changes while its webview is attached

**Given** an attached interceptor for a site at Pro
**When** the site is moved to Light and the webview re-attaches
**Then** the interceptor evaluates at Light
**And** the cached host tiers are still used

## MODIFIED Requirements

### Requirement: DNS-005 - Per-Site Toggle

Each site SHALL have a `dnsBlockEnabled` setting (default: `true`) that
controls whether DNS blocking is applied, and a `dnsBlockLevel` setting
(default: `null`) that controls how strict it is when applied. The toggle wins:
with it off the site blocks nothing regardless of its level.

Both settings SHALL apply to every request path the site drives — navigation,
the iOS/macOS JS interceptor, and the Android native sub-resource interceptor
(DNS-022) — and SHALL ride the nested-webview config so a cross-domain link
inherits them.

#### Scenario: Disable DNS blocking for a site

**Given** a site has DNS blocking disabled in its settings
**When** the site navigates to a blocked domain
**Then** navigation is allowed

#### Scenario: Default enabled

**Given** a new site is created
**Then** `dnsBlockEnabled` defaults to `true`

#### Scenario: Default level follows the app-wide one

**Given** a new site is created
**Then** `dnsBlockLevel` defaults to `null`
**And** the site blocks at whatever level App Settings is on

#### Scenario: Setting persists

**Given** a site has DNS blocking disabled, or a level of its own
**When** the app is restarted
**Then** the setting remains

#### Scenario: Enabling the toggle with no blocklist warns

**Given** no blocklist has been downloaded
**When** the user enables the DNS Blocklist toggle in site settings
**Then** the toggle flips (the setting persists and takes effect once the blocklist is downloaded)
**And** a SnackBar warns that the feature has no downloaded data and points at App Settings
**And** while the toggle is on without data, a warning icon renders next to the title and the "Not configured" subtitle is amber

#### Scenario: The level row appears only when the blocker is on

**Given** a site with DNS blocking on and a blocklist downloaded
**Then** a "Blocklist level" row sits under the toggle
**And** its subtitle names the level in use, or that the site follows the app
setting

---

### Requirement: DNS-016 - Host Decision Caches

The system SHALL maintain two host-decision caches with distinct
lifecycles. Both SHALL be bounded at 5000 entries with FIFO eviction
on insert, and cap-enforced on load (corrupted or oversized prefs blobs
SHALL NOT be allowed to load past the cap).

**Merged cache** (`_domainCache`): keyed by host, value is the merged
DNS ∪ ABP decision. Populated by `recordRequest` from webview hooks
after the caller has combined both signals. Persisted to
SharedPreferences under `dns_domain_cache`. It is app-wide and
Dart-side only: it SHALL NOT be handed to page JS (DNS-018).
Invalidated when **either** the DNS blocklist **or** the ABP rule set
changes.

**DNS-only hot-path cache** (`_dnsBlockCache`): keyed by host, value is the
host's **tier** (0 when no downloaded list names it) rather than a
blocked/allowed bit, so a site's level is applied to the cached answer instead
of baked into it. Read and written by `hostTier()`, which `isBlocked()` and
its level-aware siblings share. In-memory only, ring-buffer-backed for O(1)
eviction without iterator allocation. Invalidated when the tiers change.

#### Scenario: Cached decision reused across sites

**Given** site A's webview has previously checked `cdn.example.com` and
Dart recorded it as allowed
**When** site B's webview later encounters `cdn.example.com`
**Then** the decision is served from the merged cache on the Dart side
without re-walking the blocklist

#### Scenario: Two sites at different levels share one cached walk

**Given** site A at Light and site B at Pro both request `pro.example`
**Then** the suffix walk runs once
**And** A allows the request while B blocks it

#### Scenario: Merged cache survives app restart

**Given** the merged domain cache contains decisions
**When** the app is restarted
**Then** the cache is loaded from SharedPreferences (`dns_domain_cache`)
**And** loading stops at the 5000-entry cap even if the on-disk blob is larger

#### Scenario: Both caches invalidated on blocklist update

**Given** the user downloads a new blocklist level
**When** the download completes
**Then** the merged cache is cleared and `dns_domain_cache` is removed
**And** the DNS-only hot-path cache is cleared
**Because** previously cached tiers may be invalidated by the new partition

#### Scenario: Merged cache invalidated on ABP rule change

**Given** the user toggles or downloads a content-blocker filter list
**When** `ContentBlockerService` notifies its listeners
**Then** the merged cache is cleared via `invalidateMergedBloom`
**And** the DNS-only hot-path cache is left intact
**Because** ABP changes do not affect DNS-only decisions

#### Scenario: Cache size capped

**Given** either cache has grown to 5000 entries
**When** a new distinct host is inserted
**Then** the oldest (first-inserted) entry is evicted (FIFO)
**And** repeated inserts under load complete in O(1) time per insert
(no iterator allocation per evict on the hot path)

#### Scenario: Persistence is write-debounced

**Given** many DNS decisions occur in rapid succession
**When** `recordRequest` is called repeatedly
**Then** SharedPreferences is written once after a 2-second idle window
**And** individual writes do not block the recording path
**And** the DNS-only hot-path cache, being in-memory, is not affected
