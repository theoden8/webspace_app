# Protection Report (Block Statistics)

## Status
**Implemented**

## Purpose

Give the user a persistent, app-wide account of what the blockers actually stopped —
"N trackers blocked this week", a per-category breakdown, and an all-time total since
counting started. Mainstream privacy browsers surface this; without it the app's
blocking work is invisible and users cannot tell whether their posture is doing
anything.

## Problem Statement

Block accounting before this feature was session-scoped and per-site: `DnsStats`
(in `DnsBlockService`) counts allowed/blocked per `siteId` in memory and dies with
the process, the `StatsBanner` shows the current site's live count, and DevTools
shows engine counters. Nothing survived a restart, nothing aggregated across sites,
and nothing answered "how much did this app block for me this month".

## Solution

A pure aggregation engine (`BlockStatsEngine`, `lib/services/block_stats_engine.dart`)
holds per-category daily buckets, an all-time per-category total, and the timestamp
counting started. `BlockStatsService` (`lib/services/block_stats_service.dart`) owns
persistence, debounced writes, archive gating, and change notification.
`BlockStatsScreen` (`lib/screens/block_stats.dart`) renders the report, reachable
from App Settings.

The report is persisted in two stores with different contents, because the two halves
carry different information. The counters — per-category daily buckets, no host, no
`siteId` — are one JSON blob in plaintext SharedPreferences. The itemised detail —
what was stopped and which site it was stopped for (`BlockStatsDetail`) — is
browsing-derived, so it goes to an AES-encrypted file whose key lives in the platform
keychain (`BlockStatsDetailStore`, `lib/services/block_stats_detail_storage.dart`).

Categories are limited to what the app can actually attribute at block time. The ABP
engine returns a boolean, not the matched list, so there is no per-filter-list or
per-tracker-taxonomy split; the four categories are the four distinct mechanisms:

| Category | Source of the count |
|---|---|
| `filterList` | ABP filter-list match (`BlockSource.abp`) |
| `dnsBlocklist` | DNS blocklist match (`BlockSource.dns`) |
| `trackingParam` | ClearURLs stripped at least one parameter from a URL |
| `localCdn` | A CDN resource was served from the LocalCDN cache instead of the CDN |

---

## Requirements

### Requirement: STATS-001 - Time-Bucketed Category Counters

The system SHALL accumulate block events into per-category buckets keyed by the
**local** calendar day, so ranges match the user's own days rather than UTC.

#### Scenario: Events land in the day they happened

**Given** a block is recorded at 23:59 local time on day D
**And** another block is recorded at 00:01 local time on day D+1
**When** the report asks for the last 1 day on D+1
**Then** only the second block is counted
**And** asking for the last 2 days counts both

#### Scenario: Range windows cross month and year boundaries

**Given** blocks recorded on 30 December and 2 January
**When** the report asks for the last 7 days on 3 January
**Then** both are counted

#### Scenario: A quiet day is distinguishable from no day

**Given** a day in the window with zero recorded blocks
**When** the daily chart is rendered
**Then** that day draws no bar at all
**And** a day with any non-zero count draws a visible bar

### Requirement: STATS-002 - Persistence Across Restarts

Counters SHALL survive process death. Writes SHALL be debounced so a page load
recording hundreds of blocks does not cause hundreds of SharedPreferences writes.

The debounce is what a restart loses, so it SHALL be bounded from both ends: the
timer restarts on each event and fires once the events stop (a quiet window of at
most 3 seconds), and a ceiling of at most 10 seconds, measured from the batch's
first event, SHALL persist a page that never goes quiet.

Counters SHALL also be flushed on every step away from the foreground, not only on
`AppLifecycleState.paused`: desktop never delivers `paused`, and a foreground kill
delivers nothing at all.

A batch SHALL be treated as persisted only once its write has landed. A write that
fails, and any event recorded while a write was in flight, SHALL stay pending for
the next flush.

#### Scenario: Counters survive a restart

**Given** blocks were recorded and the app was backgrounded
**When** the app is launched again
**Then** the report shows the same all-time total and the same day buckets

#### Scenario: Burst of block events costs one write

**Given** a page load records many blocks within the debounce window
**When** the events are recorded
**Then** at most one SharedPreferences write is issued for the batch
**And** it is issued once the page goes quiet, not at the far end of the ceiling

#### Scenario: A page that never goes quiet is still persisted

**Given** a page recording a block a second, so the debounce never expires
**When** the ceiling is reached
**Then** the batch is written without waiting for the page to stop

#### Scenario: Leaving the foreground persists immediately

**Given** blocks recorded since the last write
**When** the app reports any lifecycle state other than `resumed`
**Then** the counters are flushed without waiting for the debounce

#### Scenario: A write that does not land is retried

**Given** the store cannot accept the payload
**When** the flush completes
**Then** the batch stays pending
**And** the next flush writes it

#### Scenario: Corrupt stored payload

**Given** the persisted blob is not valid JSON, or carries unknown categories,
negative counts, or malformed day keys
**When** the service initializes
**Then** it starts from the recoverable subset (empty in the unparseable case)
**And** does not throw on the startup path

### Requirement: STATS-003 - Report Surface

The user SHALL be able to open a report from App Settings showing, for a selectable
7- or 30-day range: the range total, a per-day bar chart, and each category's count
with its share of the range; plus the all-time total and the date counting started.

The app-bar shortcut into the report carries the week's count as a badge. That badge
SHALL NOT use the error colour: it counts protection that worked, and an alarm colour
reads as a fault the user has to deal with.

#### Scenario: The badge is an accent, not an alarm

**Given** a non-zero count for the last 7 days
**When** the webspaces app bar renders the protection shield
**Then** the badge is drawn in the accent role, not `colorScheme.error`

#### Scenario: Nothing blocked yet

**Given** the all-time total is zero
**When** the user opens the report
**Then** an empty state explains that per-site tracking protection has to be on
**And** the reset action is disabled

#### Scenario: Reset

**Given** the user confirms "Reset statistics"
**When** the reset completes
**Then** every counter is zero
**And** the "since" date is today
**And** the zeroed state is persisted immediately

### Requirement: STATS-004 - Bounded Retention

Daily buckets SHALL be pruned beyond a fixed retention window (90 days) so the
persisted blob cannot grow without bound. All-time totals SHALL survive pruning.

#### Scenario: Old buckets are dropped, all-time survives

**Given** a bucket older than the retention window and a bucket from today
**When** the service initializes and prunes
**Then** only the recent bucket remains in the day buckets
**And** the all-time total still includes the pruned bucket's events

### Requirement: STATS-005 - Archive Neutrality

Archive-tier sites SHALL NOT contribute to the report — neither the counters nor the
itemised detail. The report's counters live in plaintext SharedPreferences; a counter
that only advances while an archive is open would leak that the archive was used,
violating ARCH-001 active-state byte-identity and the ARCH-006 per-site feature audit.
The detail is encrypted, but it is gated by the same declaration rather than by its
encryption: one gate, checked once, so a new funnel cannot be secure in one store and
leaky in the other.

A site contributes only after its scope has been declared, keyed by `siteId`, at
webview construction (`WebViewConfig.contributesBlockStats`, sourced from
`WebViewModel.contributesBlockStats`). An undeclared `siteId` is ignored, so a path
that forgets to declare fails closed (undercount) rather than open (leak).

#### Scenario: Archive-tier site leaves no trace

**Given** a site whose scope was declared non-contributing
**When** its requests are blocked and the service flushes
**Then** the persisted key is unchanged
**And** the all-time total is unchanged

#### Scenario: Undeclared site is ignored

**Given** a block recorded for a `siteId` whose scope was never declared
**When** the record is attempted
**Then** no counter moves

#### Scenario: Moving a site into the archive stops its contributions

**Given** a contributing site is moved into the archive
**When** its scope is re-declared as non-contributing and blocks are recorded
**Then** the counters keep the pre-move total and take no new events

### Requirement: STATS-006 - Excluded from Settings Backup

The report SHALL NOT be registered in `kExportedAppPrefs`, and the detail blob SHALL
NOT be serialised into a backup at all. Backup files are emailed and synced; block
volume over time is browsing-activity history, not a user setting, and restoring one
device's activity onto another would be wrong regardless.

#### Scenario: Export omits the counters

**Given** counters with a non-zero all-time total
**When** the user exports settings
**Then** the export contains no block-statistics payload

### Requirement: STATS-007 - Nested Webviews Inherit the Scope

A cross-domain navigation opening a nested `InAppWebViewScreen` SHALL carry the
parent site's contribution scope, so an outbound link from an archive-tier site
cannot start feeding the app-wide report.

#### Scenario: Nested webview of an archive site

**Given** an archive-tier site opens a cross-domain link in a nested webview
**When** that webview blocks requests
**Then** no app-wide counter moves

### Requirement: STATS-008 - Category Drill-Down

Each category row on the report SHALL open a detail screen for that category showing:
its count over the selected range, its own per-day chart on that range, its all-time
total, and — for the current app session — what was actually stopped and which site it
was stopped for.

The itemised lists SHALL survive a restart alongside the counts they explain (STATS-009).
They are kept out of the plaintext blob, not out of persistence: hosts and `siteId`s
reach only the encrypted store.

The label a funnel supplies is the substance of its own mechanism: the blocked host for
DNS and filter-list blocks, the stripped query keys for ClearURLs, the CDN origin for a
locally served resource. A funnel that cannot name what it stopped SHALL still attribute
the event to its site.

#### Scenario: A category names what it blocked

**Given** two DNS blocks for `ads.example` and one for `beacon.example` this session
**When** the user opens the DNS category
**Then** both hosts are listed, most frequent first
**And** the filter-list category's items are not among them

#### Scenario: Per-site attribution

**Given** blocks recorded for two app-tier sites in one category
**When** the user opens that category
**Then** each site is listed by its display name with its own count

#### Scenario: Detail never reaches the plaintext blob

**Given** a block recorded with a host label
**When** the service flushes
**Then** the SharedPreferences payload contains neither the host nor the `siteId`

#### Scenario: An archive-tier site leaves no detail either

**Given** a site declared non-contributing
**When** its blocks are recorded with labels
**Then** the detail stays empty
**And** nothing is written to the detail store

#### Scenario: A site the user deleted

**Given** a per-site count for a `siteId` that no longer has a display name
**When** the user opens that category
**Then** the row is omitted rather than shown as a raw `siteId`

#### Scenario: Nothing itemised, counters non-zero

**Given** a category with a non-zero persisted total and no itemised rows
**When** the user opens it
**Then** the counts and the chart still render
**And** the itemised area says nothing has been recorded yet

#### Scenario: Bounded memory

**Given** more distinct items in one category than the per-category cap
**When** further items are recorded
**Then** the least frequent are evicted
**And** the most frequent item is still listed

#### Scenario: Reset clears the detail

**Given** recorded items and per-site counts
**When** the user resets the statistics
**Then** the itemised lists are empty alongside the zeroed counters

---

### Requirement: STATS-009 - Detail Persistence, Encrypted

The itemised detail SHALL survive process death, and SHALL reach disk only encrypted:
an AES-256-CBC blob under the app's documents directory whose key lives in
`flutter_secure_storage`. Hosts and `siteId`s SHALL NOT be written anywhere in
plaintext. There SHALL be no plaintext fallback: where the key or the file cannot be
had, the detail degrades to memory-only and the counters carry on.

Rows SHALL be bounded the same way in the store as in memory — the per-category cap on
load, and the counters' retention window (90 days) measured from each row's last-seen
time. Per-site rows SHALL be reclaimed by the orphan sweep for sites outside the live
non-incognito set, so a deleted site's row does not outlive the site and an incognito
site's row does not outlive the launch.

#### Scenario: Items and per-site counts survive a restart

**Given** blocks recorded with host labels for a named site, then a flush
**When** the app is launched again and the user opens that category
**Then** the same hosts are listed with the same counts
**And** the same site is named with its own count

#### Scenario: The blob on disk is not readable as text

**Given** a block recorded with a host label
**When** the detail is persisted
**Then** the bytes on disk contain neither the host nor the `siteId`

#### Scenario: A block recorded before the load is not overwritten

**Given** a stored blob for a host and a block recorded for the same host while the
load is still in flight
**When** the load completes
**Then** the row carries both counts

#### Scenario: Reset is not undone by the next launch

**Given** the user confirmed a reset
**When** the app is launched again
**Then** the itemised lists are still empty

#### Scenario: Unreadable detail costs the items, not the counters

**Given** a stored detail blob that cannot be decrypted or parsed
**When** the service initializes
**Then** the counters load as usual
**And** the itemised lists start empty without throwing on the startup path

#### Scenario: No secure storage on the device

**Given** a platform where the keychain read fails
**When** blocks are recorded and flushed
**Then** the counters still persist
**And** nothing is written to the detail file

#### Scenario: Rows age out with the buckets

**Given** a row last seen beyond the retention window and one seen today
**When** the service initializes and prunes
**Then** only the recent row remains

#### Scenario: A deleted site's row is reclaimed

**Given** per-site rows for a live site and for one the user has deleted
**When** the orphan sweep runs
**Then** only the live site's row remains
**And** the host counts the deleted site contributed are untouched

---

## Implementation Notes

- **Single funnel.** DNS/ABP block accounting on every platform already passes through
  `DnsBlockService.recordHostRequest` (the Android native interceptor drains into it,
  the iOS/macOS JS bridge calls it per URL, navigation checks call it). The report
  hooks that one place, so the aggregate cannot drift from the per-site counters.
- **No siteId reaches plaintext.** Only per-category daily totals go to
  SharedPreferences, so that blob cannot be mined for which sites the user visits. The
  STATS-008 drill-down's hosts and per-site counts (`BlockStatsDetail`) persist through
  the encrypted store instead, gated by the same `setSiteContributes` declaration as
  the counters, so an undeclared site fails closed in both.
- **Why not one store.** Putting the detail in the plaintext blob would leak browsing
  history; keeping it in memory to avoid that is what made the drill-down reset on
  every restart while the counts above it did not — two halves of one screen
  disagreeing. Encrypting the half that names things settles both.
- **Per-site live counters are unchanged.** `DnsStats` and the `StatsBanner` stay
  in-memory and session-scoped; this feature is additive.
- Files: `lib/services/block_stats_engine.dart`, `lib/services/block_stats_detail.dart`,
  `lib/services/block_stats_detail_storage.dart`, `lib/services/block_stats_service.dart`,
  `lib/screens/block_stats.dart`. Tests: `test/block_stats_engine_test.dart`,
  `test/block_stats_service_test.dart`, `test/block_stats_detail_test.dart`,
  `test/block_stats_detail_storage_test.dart`, `test/block_stats_screen_test.dart`.
  Structural gate for STATS-007: `test/js/nested_webview_posture_parity.test.js`
  (`contributesBlockStats` is POSTURE); for the STATS-002 lifecycle flush:
  `test/js/block_stats_flush_lifecycle.test.js`.
- **Why the flush is not on `paused` alone.** `paused` is the Android/iOS
  backgrounding signal; desktop delivers `inactive`/`hidden`/`detached` instead, and
  a kill from the foreground delivers nothing. Gating the write on a dirty flag makes
  the wider trigger free: a transient `inactive` with nothing new recorded does no
  I/O. Same class of gap as the capture-side kill paths in
  [docs/bugs/003-cold-start-history-loss.md](../../../docs/bugs/003-cold-start-history-loss.md).
