## 1. Partition the DNS blocklist

- [x] 1.1 Add `lib/services/dns_tier_engine.dart`: `DnsTiers` (disjoint tiers,
  `tierOf`, `blockedAt`), `DnsTiersBuilder` (ascending, streamed so a level's
  raw set never sits beside the tiers), `resolveDnsLevel`,
  `dnsLevelNeedsDownload`, `requiredDnsLevels`.
- [x] 1.2 Hold tiers in `DnsBlockService` instead of the flat set; expose
  `downloadedLevels`, `tierDomains`, `tiersByLevel`, `effectiveLevelFor`.
- [x] 1.3 Cache the host's tier rather than a blocked bit
  (`HostFifoCache<int>`), so per-site levels add no cache entries.
- [x] 1.4 One cache file per level, with the pre-tier single file migrated on
  first launch; persist `dns_block_downloaded_levels`.
- [x] 1.5 `downloadLevel(level)` for on-demand fetches and `pruneLevels(keep)`
  for reclaiming levels nothing asks for, both on the existing mutation chain.

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

- [x] 3.1 `DnsHostBlocklist` holds tiers, parses `#<level>` markers, answers
  `tierOf` / `isBlockedAt`.
- [x] 3.2 `sendDnsTiers` ships the partition; `attachToWebViews` carries the
  site's level.
- [x] 3.3 `FastSubresourceInterceptor` caches tiers and applies a volatile
  `dnsLevel`; the plugin remembers each site's level so an attach that names
  none cannot promote a site back to full strength.

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

## 5. Settings UI

- [x] 5.1 "Blocklist level" row under the DNS toggle: level picker, the
  app-setting default, the not-downloaded state, and the on-demand fetch.
- [x] 5.2 "Filter lists" row under the content-blocker toggle: a checklist of
  the app's enabled lists.
- [x] 5.3 Ten new ARB keys, translated across every shipped locale.

## 6. Tests

- [x] 6.1 `test/dns_tier_engine_test.dart`: partition, lowest-tier-wins,
  subdomain inheritance, level resolution and fallback, required levels.
- [x] 6.2 `test/dns_block_service_test.dart`: per-site levels over a real tier
  set, one cached walk serving several levels, fallback when a level has no
  list.
- [x] 6.3 `test/filter_list_mask_test.dart`: the rewrite string by string, and
  — against the real adblock-rust library — that a masked rule stops blocking
  on the masked site only, that an existing `$domain=` survives, and that a
  masked generic hide stays generic and comes back as an exception.
- [x] 6.4 `DnsHostBlocklistTest.kt`: marker parsing, tier lookup, level
  masking, lowest-suffix-wins.
