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

- **The DNS blocklist becomes a per-domain level-membership mask.** One bit
  per severity level, set when that level's own list names the domain. The
  obvious compression — store the lowest level that names it and block at
  everything above — assumes the levels nest, and they do not: 21,921 of the
  297,756 domains across Hagezi's five lists drop out of a higher level, so
  that model would have made the *app-wide* level block more as soon as some
  site caused a lower level to be downloaded. Domains are grouped by mask, so
  the entry count is exactly the union and one downloaded level is one group.
  New pure-Dart engine
  [`dns_level_mask_engine.dart`](../../../lib/services/dns_level_mask_engine.dart)
  (DNS-019).
- **Per-site DNS level.** `WebViewModel.dnsBlockLevel` (null = follow the
  app-wide level). The per-host decision cache stores the host's *level mask*
  rather than a blocked/allowed bit, so every site bit-tests one cached
  answer: no extra cache entries, no extra suffix walks (DNS-020).
- **Levels are fetched on demand, and stored once.** The App Settings download
  is unchanged — one list, one level. Picking a per-site level the app has no
  list for fetches it and folds its bit into the stored mask; the whole
  blocklist lives in one file whose domain content is the union, so disk stays
  the size of the largest list rather than the sum of the downloaded ones.
  Until a level lands, the site runs at the app-wide level: its bit means
  nothing yet, and evaluating against the mask anyway would block *nothing*,
  which is the one direction a relaxation must not go (DNS-021).

  Over the wire this is cheaper than it looks — jsDelivr gzips, so Light is
  294 KB and Ultimate 1.97 MB transferred, against 806 KB and 5.29 MB raw.
- **Per-site filter lists.** `WebViewModel.disabledFilterLists` names list ids
  the site opts out of. The mask is compiled into the rules at engine-build
  time using adblock-rust's own domain scoping — `$domain=~host` on network
  rules, `~host##selector` on cosmetic ones — so one engine answers every site
  and no decision site consults the mask (CB-015).
- **Android sub-resources learn the site's DNS posture.** The native
  interceptor evaluated the app-wide blocklist for every site, so per-site
  `dnsBlockEnabled: false` never reached Android sub-resource fetches. It now
  carries the site's level, which subsumes the old boolean (DNS-022).

## Measured

- **The filter-list mask is indistinguishable from removing the list.** Built
  as a differential over EasyList + EasyPrivacy: a corpus of 208,669 URLs
  harvested from the rules themselves, four request types each — 834,676
  network decisions. On the masked site the masked engine agrees with an
  engine built *without* EasyList on every one; on every other site it agrees
  with an engine built with both. Cosmetic hide sets match too (428 selectors
  on an unmasked host, 0 on the masked one, both engines). The fixture-scale
  version of that differential is committed.
- **The level mask costs nothing until a second level exists.** Same data
  (Pro, 225,134 domains): flat set +38 MB RSS and 0.99 µs per uncached miss,
  mask +31 MB and 0.89 µs. Adding Light: 3 groups, 229,939 domains, +31 MB,
  1.56 µs. All five levels: 15 groups, 297,756 domains, 4.94 µs. The cost
  falls only on a host's first sight — the per-host cache serves every
  repeat, and every site, from one number.

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
  only for plain hides). Counted on the shipped lists: EasyList and
  EasyPrivacy carry zero `$badfilter`, zero generic scriptlets and zero
  generic procedurals between them, and EasyList's 336 cosmetic unhides are
  no-ops once the hides they cancel are already suppressed — which is why the
  full-scale differential is clean. The shapes appear in uBO-style lists, and
  the exclusions are pinned by a test so they can be lifted if adblock-rust
  ever makes them scopable.
- **Archive-tier sites carry neither mask** (ARCH-006). A per-site level pins a
  downloaded level file and a per-site list selection rewrites the shared
  engine cache blob — both are traces outside the archive's keyspace whose
  presence would vary with whether an archive is open.

## Impact

- Specs: `dns-blocklist` (DNS-019..DNS-022, DNS-005 and DNS-016 modified),
  `content-blocker` (CB-015, CB-006 modified), `site-settings-qr` (QR-008
  modified: a payload that only lowers the level or masks a list off weakens
  the blockers without moving either toggle, so the review gate names both).
- Code: `dns_level_mask_engine.dart`, `filter_list_mask.dart` (both new),
  `dns_block_service.dart`, `content_blocker_service.dart`, `web_view_model.dart`,
  `webview.dart`, `web_intercept_native.dart`, `main.dart`, the site privacy
  screen, `DnsHostBlocklist.kt`, `WebInterceptPlugin.kt`.
- Storage: the blocklist cache is one file of `#<mask-hex>` sections
  (`dns_blocklist_levels.txt`) holding each domain once; the pre-mask flat file
  is migrated on first launch. New machine-state prefs `dns_block_downloaded_levels` and
  `content_blocker_list_masks` (neither is exported — both are derived).
