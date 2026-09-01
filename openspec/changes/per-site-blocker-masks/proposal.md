## Why

The two downloaded-data blockers are configurable app-wide and binary per
site. App Settings picks a DNS severity level (Off through Ultimate) and which
ABP filter lists to run; a site's own settings can only switch each of them
off entirely.

That leaves one move when a site breaks: give up all of that protection for
it. Issue #566 asks for the obvious middle — drop the site to a weaker DNS
level, or turn off the one filter list that broke it, and keep the rest.

The reason it was binary is memory. A per-site level naively means holding
that level's blocklist too: Hagezi's lists run 60K to 650K domains, and five
of them in memory is not a trade anyone would take for a per-site preference.
A per-site filter-list selection naively means a second adblock-rust engine
per distinct selection, which is tens of megabytes each.

Neither is necessary. Both settings are *subsets* of the app-wide
configuration, and a subset is a mask, not a copy.

## What Changes

- **The DNS blocklist becomes a partition, not a set.** Each domain is stored
  under the lowest severity level whose list names it, so "blocked at level N"
  is "sits in some tier 1..N". Tiers are disjoint, so the entry count across
  all of them equals the size of the largest downloaded list — the same memory
  the flat set used. New pure-Dart engine
  [`dns_tier_engine.dart`](../../../lib/services/dns_tier_engine.dart)
  (DNS-019).
- **Per-site DNS level.** `WebViewModel.dnsBlockLevel` (null = follow the
  app-wide level). The per-host decision cache stores the host's *tier* rather
  than a blocked/allowed bit, so every site masks one cached answer with its
  own level: no extra cache entries, no extra suffix walks (DNS-020).
- **Levels are fetched on demand.** The App Settings download is unchanged —
  one file, one level. Picking a per-site level the app has no list for fetches
  that level's list and folds it into the partition. Until it lands, the site
  runs at the app-wide level: the tier boundary it asked for does not exist
  yet, and evaluating against the tiers anyway would block *nothing*, which is
  the one direction a relaxation must not go (DNS-021).
- **Per-site filter lists.** `WebViewModel.disabledFilterLists` names list ids
  the site opts out of. The mask is compiled into the rules at engine-build
  time using adblock-rust's own domain scoping — `$domain=~host` on network
  rules, `~host##selector` on cosmetic ones — so one engine answers every site
  and no decision site consults the mask (CB-015).
- **Android sub-resources learn the site's DNS posture.** The native
  interceptor evaluated the app-wide blocklist for every site, so per-site
  `dnsBlockEnabled: false` never reached Android sub-resource fetches. It now
  carries the site's level, which subsumes the old boolean (DNS-022).

## Trade-offs and limits

- **A mask can only clear bits.** A per-site level above the app-wide one, or
  a filter list not enabled in App Settings, has no data behind it. The level
  case is handled by fetching on demand; a list the app does not run cannot be
  turned on for one site.
- **The filter-list mask keys off the site's registrable host**, because that
  is what `$domain=` matches. Two sites on the same host share a mask, and a
  masked site that navigates to another domain is outside its own scoping for
  the duration.
- **Three rule shapes are left global** because scoping them would change what
  they do for everyone rather than exempting one site: `$badfilter` (it cancels
  by matching options), cosmetic unhide (`#@#` — adblock-rust rejects a rule
  that is both an unhide and domain-negated), and generic scriptlet/procedural
  rules (a generic rule with only negated hostnames keeps applying elsewhere
  only for plain hides). EasyList and EasyPrivacy carry zero generic
  procedurals today; the shape appears in uBO-style lists.
- **Archive-tier sites carry neither mask** (ARCH-006). A per-site level pins a
  downloaded level file and a per-site list selection rewrites the shared
  engine cache blob — both are traces outside the archive's keyspace whose
  presence would vary with whether an archive is open.

## Impact

- Specs: `dns-blocklist` (DNS-019..DNS-022, DNS-005 and DNS-016 modified),
  `content-blocker` (CB-015, CB-006 modified).
- Code: `dns_tier_engine.dart`, `filter_list_mask.dart` (both new),
  `dns_block_service.dart`, `content_blocker_service.dart`, `web_view_model.dart`,
  `webview.dart`, `web_intercept_native.dart`, `main.dart`, the site privacy
  screen, `DnsHostBlocklist.kt`, `WebInterceptPlugin.kt`.
- Storage: the blocklist cache is now one file per downloaded level
  (`dns_blocklist_<level>.txt`); the pre-tier single file is migrated on first
  launch. New machine-state prefs `dns_block_downloaded_levels` and
  `content_blocker_list_masks` (neither is exported — both are derived).
