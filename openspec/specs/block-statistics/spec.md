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
persistence (one JSON blob in SharedPreferences), debounced writes, archive gating,
and change notification. `BlockStatsScreen` (`lib/screens/block_stats.dart`) renders
the report, reachable from App Settings.

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
recording hundreds of blocks does not cause hundreds of SharedPreferences writes,
and SHALL be flushed when the app is backgrounded.

#### Scenario: Counters survive a restart

**Given** blocks were recorded and the app was backgrounded
**When** the app is launched again
**Then** the report shows the same all-time total and the same day buckets

#### Scenario: Burst of block events costs one write

**Given** a page load records many blocks within the debounce window
**When** the events are recorded
**Then** at most one SharedPreferences write is issued for the batch

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

Archive-tier sites SHALL NOT contribute to the report. The report's counters live in
plaintext SharedPreferences; a counter that only advances while an archive is open
would leak that the archive was used, violating ARCH-001 active-state byte-identity
and the ARCH-006 per-site feature audit.

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

The report SHALL NOT be registered in `kExportedAppPrefs`. Backup files are emailed
and synced; block volume over time is browsing-activity history, not a user setting,
and restoring one device's activity onto another would be wrong regardless.

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

---

## Implementation Notes

- **Single funnel.** DNS/ABP block accounting on every platform already passes through
  `DnsBlockService.recordHostRequest` (the Android native interceptor drains into it,
  the iOS/macOS JS bridge calls it per URL, navigation checks call it). The report
  hooks that one place, so the aggregate cannot drift from the per-site counters.
- **No siteId is persisted.** Only per-category daily totals reach disk, so the blob
  cannot be mined for which sites the user visits.
- **Per-site live counters are unchanged.** `DnsStats` and the `StatsBanner` stay
  in-memory and session-scoped; this feature is additive.
- Files: `lib/services/block_stats_engine.dart`, `lib/services/block_stats_service.dart`,
  `lib/screens/block_stats.dart`. Tests: `test/block_stats_engine_test.dart`,
  `test/block_stats_service_test.dart`. Structural gate for STATS-007:
  `test/js/nested_webview_posture_parity.test.js` (`contributesBlockStats` is POSTURE).
