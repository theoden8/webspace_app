# DNS Blocklist — per-site level delta

## ADDED Requirements

### Requirement: DNS-019 - Level-Membership Storage

The downloaded blocklists SHALL be held as a per-domain **level-membership
mask**: one bit per severity level, set when that level's own list names the
domain. "Blocked at level N" SHALL mean "bit N is set", never "some lower
level named it".

Hagezi describes the five levels as building on each other, and they do not.
Across the published lists, 21,921 of the 297,756 domains drop out of a
higher level — 1,455 are in Light and in nothing above it, 11,518 are in
Normal and not in Pro. A "lowest level that names it" model would block those
at every level above, which would make the **app-wide** level's behaviour
change depending on which per-site levels happened to be downloaded. The mask
is the only model that keeps a level meaning exactly what its own list says.

Domains SHALL be stored as disjoint groups keyed by that mask, so the entry
count across all groups is exactly the union of the downloaded lists — what a
flat set of that union costs — and one downloaded level is one group, which is
where an install that never sets a per-site level stays. Measured on the real
lists: Pro alone is 225,134 domains in 1 group; Pro plus Light is 229,939 in 3.

Groups are built by [`DnsLevelSetsBuilder`](../../../../../lib/services/dns_level_mask_engine.dart),
which is fed one domain at a time. A level's raw parsed list SHALL NOT be
materialised as a set alongside the groups it is being folded into — that is
the one place this structure could cost more memory than the flat set it
replaces.

The whole blocklist SHALL be cached in **one** file (`dns_blocklist_levels.txt`)
of `#<mask-hex>` sections, so a domain is stored once however many levels name
it and disk stays the size of the largest list rather than the sum of the
downloaded ones. The set of downloaded levels is persisted under
`dns_block_downloaded_levels`.

#### Scenario: A domain carries a bit per level that names it

**Given** `shared.example` appears in the Light and Pro lists and
`light.example` only in Light
**When** both are downloaded
**Then** `shared.example` carries the Light and Pro bits
**And** `light.example` carries the Light bit only

#### Scenario: A level blocks only what its own list named

**Given** `light.example` is named by Light and by no higher level
**When** a site running at Pro requests it
**Then** the request is allowed
**And** a site running at Light blocks it

#### Scenario: Downloading a lower level does not change the app-wide one

**Given** the app-wide level is Pro
**When** a site causes Light to be downloaded
**Then** every site on the app-wide level blocks exactly what Pro named,
unchanged

#### Scenario: The union is stored once

**Given** several levels are downloaded
**Then** each domain appears exactly once in the cache file
**And** the domain count equals the union of the downloaded lists

#### Scenario: The pre-mask cache is migrated

**Given** an install that cached one flat list under `dns_blocklist.txt` at
level 3
**When** the app starts after upgrading
**Then** those domains are folded in carrying the level-3 bit
**And** the flat file is deleted
**And** the blocklist is available without a network request

---

### Requirement: DNS-020 - Per-Site Severity Level

Each site SHALL have a `dnsBlockLevel` setting (default `null`, meaning
"follow the app-wide level"). A site with a resolved level of N SHALL block
exactly the domains whose mask carries level N's bit — what level N's own
list named, not what any lower level did. Level 0 blocks nothing.

The per-host decision cache SHALL store the host's level mask, not a blocked
or allowed bit, so one cached answer serves every site whatever level it runs
at: each site bit-tests the same number.

The site's own toggle and its level SHALL be resolved into one number at the
call site (`WebViewConfig.effectiveDnsLevel`): 0 when the toggle is off,
otherwise the resolved level. Decision sites SHALL consult that number rather
than the toggle and the level separately.

#### Scenario: A site relaxes below the app-wide level

**Given** the app-wide level is Pro and the Light list is downloaded
**And** a site is set to Light
**When** the site requests a domain the Pro list names and Light does not
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
**Then** the host's level mask is computed once and cached
**And** each site's decision is one bit test on that mask

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
resolve to the app-wide level. Its bit means nothing until then, so evaluating
against the mask would block nothing at all, which is the one direction a
relaxation must never take. Level 0 needs no list and SHALL always resolve to
itself.

A newly fetched level SHALL be folded into the stored partition — its bit set
on the domains it names and cleared on the ones it does not — rather than kept
as a separate list.

A level no site asks for and that is not the app-wide level SHALL be dropped —
its bit cleared, and any domain no remaining level names removed — during the
deferred startup sweep, and not on the per-save path, where an unsaved edit
would not yet name it.

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
**Then** the Light bit is cleared from every domain
**And** the domains no other level named are freed

---

### Requirement: DNS-022 - Android Sub-Resources Honour the Site's Level

The native sub-resource interceptor SHALL evaluate each request at the level of
the site whose webview it is attached to. The blocklist it consults is
app-wide, so the level passed at attach time is the only place an Android
sub-resource learns the site's DNS posture.

The blob pushed to the native side SHALL carry the groups: a `#<mask-hex>`
marker line introduces each one, and a domain appears once however many levels
name it. A blob with no marker SHALL load as level 1 so an older payload still
parses.

The interceptor's per-host cache SHALL hold level masks, so a level change
moves the site's decisions without invalidating the cache. An attach call that names no
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
**And** the cached host masks are still used

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
host's **level mask** (0 when no downloaded list names it) rather than a
blocked/allowed bit, so a site's level bit-tests the cached answer instead of
being baked into it. Read and written by `hostLevelMask()`, which
`isBlocked()` and its level-aware siblings share. In-memory only,
ring-buffer-backed for O(1) eviction without iterator allocation. Invalidated
when the groups change.

#### Scenario: Cached decision reused across sites

**Given** site A's webview has previously checked `cdn.example.com` and
Dart recorded it as allowed
**When** site B's webview later encounters `cdn.example.com`
**Then** the decision is served from the merged cache on the Dart side
without re-walking the blocklist

#### Scenario: Two sites at different levels share one cached walk

**Given** site A at Light and site B at Pro both request a host Pro names and
Light does not
**Then** the suffix walk runs once and the mask is cached
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
**Because** previously cached masks may be invalidated by the new groups

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
