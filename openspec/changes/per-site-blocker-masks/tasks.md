## 1. Partition the DNS blocklist

- [x] 1.1 Add `lib/services/dns_level_mask_engine.dart`: `DnsLevelSets`
  (disjoint groups keyed by level-membership mask, `maskOf`, `blockedAt`),
  `DnsLevelSetsBuilder` (streamed, folds a level into an existing partition,
  drops one), `resolveDnsLevel`, `dnsLevelNeedsDownload`, `requiredDnsLevels`.
- [x] 1.2 Hold the groups in `DnsBlockService` instead of the flat set; expose
  `downloadedLevels`, `domainsAtLevel`, `levelGroups`, `effectiveLevelFor`.
- [x] 1.3 Cache the host's level mask rather than a blocked bit
  (`HostFifoCache<int>`), so per-site levels add no cache entries.
- [x] 1.4 One cache file of `#<mask-hex>` sections holding each domain once,
  with the pre-mask flat file migrated on first launch; persist
  `dns_block_downloaded_levels`.
- [x] 1.5 `downloadLevel(level)` folds a level's bit in; `pruneLevels(keep)`
  clears the bits nothing asks for and drops the domains left with none. Both
  on the existing mutation chain.

## 2. Per-site DNS level

- [x] 2.1 `WebViewModel.dnsBlockLevel` + `effectiveDnsBlockLevel` (null for
  archive-tier, ARCH-006), through `toJson`/`fromJson` with an out-of-range
  value read as "follow the app setting".
- [x] 2.2 Thread it through `WebViewConfig`, `launchUrl`, `InAppWebViewScreen`,
  the `LaunchUrlFunc` typedef and both nested call sites.
- [x] 2.3 `WebViewConfig.effectiveDnsLevel` folds the toggle and the level into
  one number; every DNS decision site in `webview.dart` reads it.
- [x] 2.4 Record navigation stats at the site's level, so a site with blocking
  off no longer logs blocks it did not make.
- [x] 2.5 Classify the new keys in the QR codec; prune abandoned levels in the
  deferred startup sweep.

## 3. Android sub-resources

- [x] 3.1 `DnsHostBlocklist` holds the groups, parses `#<mask-hex>` markers,
  answers `maskOf` / `isBlockedAt`.
- [x] 3.2 `sendDnsLevelGroups` ships the groups; `attachToWebViews` carries
  the site's level.
- [x] 3.3 `FastSubresourceInterceptor` caches level masks and bit-tests a
  volatile `dnsLevel`; the plugin remembers each site's level so an attach
  that names none cannot promote a site back to full strength.

## 4. Per-site filter lists

- [x] 4.1 Add `lib/services/filter_list_mask.dart`:
  `scopeRulesAwayFromHosts`, mirroring adblock-rust's rule classification and
  option split, leaving `$badfilter`, cosmetic unhide and generic
  scriptlet/procedural rules alone.
- [x] 4.2 `WebViewModel.disabledFilterLists` + `effectiveDisabledFilterLists`
  (empty for archive-tier), through the same five plumbing sites.
- [x] 4.3 `ContentBlockerService.setListMasks`, applied at rebuild, persisted
  so the first build of a launch already carries it, and a no-op when the mask
  did not move.
- [x] 4.4 Push the mask from the site-save funnel, keyed by each site's
  registrable host.
- [x] 4.5 Strip options before the regex test in `parseAbpNetworkPrefilter`,
  so a masked regex rule keeps forcing a round-trip instead of being tokenized
  on a literal it does not guarantee.

## 5. Settings UI

- [x] 5.1 "Blocklist level" row under the DNS toggle: level picker, the
  app-setting default, the not-downloaded state, and the on-demand fetch.
- [x] 5.2 "Filter lists" row under the content-blocker toggle: a checklist of
  the app's enabled lists.
- [x] 5.3 Ten new ARB keys, translated across every shipped locale.
- [x] 5.4 Name both relaxations in the QR review gate: a payload can lower the
  level or mask a list off without moving either protection toggle.

## 6. Tests

- [x] 6.1 `test/dns_level_mask_engine_test.dart`: grouping, a level naming
  exactly its own list over deliberately non-nesting inputs, subdomain
  inheritance, re-adding and dropping a level, level resolution and fallback,
  required levels.
- [x] 6.2 `test/dns_block_service_test.dart`: per-site levels over a
  non-nesting set, one cached mask serving several levels, fallback when a
  level has no list, and a disk round-trip that preserves every level's
  membership with each domain stored once.
- [x] 6.3 `test/filter_list_mask_test.dart`: the rewrite string by string, and
  — against the real adblock-rust library — that a masked rule stops blocking
  on the masked site only, that an existing `$domain=` (positive or negated)
  survives the merge, that `$removeparam`, `$csp` and `$important` rules mask
  like plain ones, and that a masked generic hide stays generic and comes back
  as an exception.
- [x] 6.4 `DnsHostBlocklistTest.kt`: `#<mask-hex>` parsing, mask lookup, a
  level blocking only its own list, suffix union.
- [x] 6.5 `test/filter_list_mask_test.dart`: a differential proving the mask
  is indistinguishable from not having the list — the masked engine against
  one built without it for the masked site, and against one built with both
  for every other site, over a corpus derived from the rules. Run at full
  scale on EasyList + EasyPrivacy during development (834,676 decisions, zero
  divergence); committed at fixture scale. The shapes left global are pinned
  by their own test.
- [x] 6.6 `test/dns_block_benchmark_test.dart`: one downloaded level is one
  group, a second adds only its own domains, and the lookup stays under the
  per-call ceiling.
- [x] 6.7 `test/dns_block_level_storage_test.dart`: the download and disk path
  end to end over a fake mirror — a level writes one file plus its prefs, a
  second folds in without duplicating a shared domain, a level already held
  costs no request, a missing mirror and an implausibly short body leave the
  partition alone, a re-download drops delisted domains, a cold start
  reproduces every level, and the group marker is hex (levels 2+4, mask `a`,
  where decimal and hex diverge). Legacy flat-file migration, prune, and
  clearing to level 0 included.
- [x] 6.8 `test/content_blocker_list_mask_test.dart`: the mask round-trips
  through prefs with its hosts sorted, an empty selection is dropped, a
  malformed or partly non-string blob degrades to none, and a rebuild is paid
  only when the mask actually moves.
- [x] 6.9 `test/web_view_model_test.dart`: `dnsBlockLevel` and
  `disabledFilterLists` through `toJson`/`fromJson`, defaults omitted, an
  out-of-range or wrong-typed level read as "follow the app setting", and both
  suppressed for archive-tier sites.
- [x] 6.10 `test/js/dns_level_blob_format.test.js`: structural gate that the
  Dart writers and the Kotlin reader agree on the `#`-plus-hex marker, the
  level-bit formula, the level range, and the unmarked-blob-is-level-1
  fallback. Nothing else links the two sides of the platform channel.
