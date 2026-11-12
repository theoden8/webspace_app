# Tasks

Builds on `inactive-tabs` (the tab model and hosted tabs). Requirements:
TAB-002, TAB-003, TAB-011 (modified), TAB-023 to TAB-028, PAUSE-006,
PAUSE-012, CONT-003. Design: `design.md`.

## 1. The model first

- [ ] 1.1 `formal/retention.tla`: the four warm tiers below `loaded` (design D2); a demonstrator that evicts a site's active webview while a warm tab of another site is loaded, which TLC MUST reject (TAB-024); `./formal/check.sh` green.
- [ ] 1.2 Record the `Finished in` of `activation_gen_jar_cold_tabs_reset_one` (the costliest tab world) and of `activation.cfg` before any change, to name in the PR with the after figures.
- [ ] 1.3 `formal/activation.tla` through the tables and the printer, not by hand (design D5, shape B): `built` and `hist` unchanged; a `warm` `ModelVar` over `Tabbed`, its leaf the code's per-tab live views; the `Live` `Def` read by the cap and the limit; `Inv_WarmShown`, `Inv_WarmListed`, `Inv_WarmLoaded`, each with its own `Mutant` in `checks.dart` naming the world that catches it. `MaxWarm` 1 in the printed tab worlds, one written world at 2, one link world at 1. Verify: `./formal/verify.sh` passes; `activation.cfg`'s distinct states unchanged; `activation_footprints.tsv`'s sharing pairs not grown; every new mutant caught.

## 2. Webviews as the residency unit

- [ ] 2.1 `LiveView` (`({SiteId owner, TabId tab})`) and the warm tiers in `SiteRetentionPriority`; `evictionOrder` over `LiveView`s. Verify: `test/site_retention_priority_test.dart` cases named for TAB-024 (the order of the four tiers, LRU within each).
- [ ] 2.2 `SiteUnloadEngine.plan` over `LiveView`s: the LRU cap counts views (CONT-003), a `TabLeft` event applies the warm limit before the cap (TAB-023). Verify: boundary tests named for TAB-023 (fourth own tab, hosted raises the limit, hosted before own) and CONT-003 (twenty views, warm tab taken first).
- [ ] 2.3 `SiteLifecyclePromotionEngine` tiers per view, proactive pass and pressure plan counting views. Verify: tests named for PAUSE-006 ("pressure takes a warm tab before a background site") and PAUSE-012 ("warm tabs count toward the threshold").
- [ ] 2.4 `RuntimeVars.loaded` stays a set of sites; the plan's count reads the printed view-count `Def` over `loaded` and `built`. Verify: `./formal/trace/check_steps.sh` replays green.

## 3. The switch

- [ ] 3.1 `WebViewTabBinding` per tab: `built` a set, bytes still tagged with their tab (TAB-003, BUG-036). Verify: its unit tests and the tab schedules in `test/activation_schedules_test.dart`.
- [ ] 3.2 `TabTable` switch: a warm target in one turn with no await; a parked target reads its bytes, then in one turn leaves the active tab warm, builds the target, then plans `TabLeft` (design D4). Verify: schedules named for TAB-003 ("switching to a warm tab", "the tab left cannot stay warm"); `check_steps.sh` green.
- [ ] 3.3 Name `Finished in` after, beside 1.2's figures, in the PR; past about 10% growth in the costliest tab world, look first at memory pressure's plan against the tab flow.

## 4. A warm tab acts as nothing

- [ ] 4.1 A per-view pause that does not skip notification and background-audio sites; going warm pauses (design D6). Verify: a test named for TAB-025 that a notification site's warm view is paused.
- [ ] 4.2 Capture ends per view when its tab goes warm: `ScreenShare.endView`, the camera and microphone stop. Verify: a test named for TAB-025 ("a share ends when its tab goes warm").
- [ ] 4.3 The notification bridge drops a post from a view that is not its site's active one, at the handler. Verify: a test named for TAB-025 ("a warm tab does not notify").

## 5. Running identity and unloads

- [ ] 5.1 `SlotIdentities` per view; domain conflict, proxy mismatch and Tor exit mismatch judge each view by its running identity and take every view running as the site (TAB-026, TAB-027). Verify: boundary tests named for both, one on Android without router mode.
- [ ] 5.2 Legacy shared jar: the site's cookie capture runs once, after its last view is disposed. Verify: `test/cookie_isolation_integration_test.dart` case named for TAB-027 with `MockCookieManager`.

## 6. The slot and the tab list

- [ ] 6.1 The slot under `ValueKey(siteId)` holds a `KeyedSubtree` per live tab, the shown one on top, and none once unloaded (TAB-026, design D7). Verify: a widget test that a switch to a warm tab keeps the same element (no remount).
- [ ] 6.2 The tab list draws a warm tab at full strength without the selected highlight, and tells a screen reader its state (TAB-011). Verify: a widget test named for TAB-011.

## 7. Persistence

- [ ] 7.1 A switch captures the tab it leaves before its turn whether the tab goes warm or is parked, and a warm view is disposed with no capture (TAB-028). Verify: a test named for TAB-028 that a tab gone warm has its bytes saved under its own key and that evicting it writes nothing.

## 8. Measure and document

- [ ] 8.1 Android: N tabs of one site against N sites on the emulator, the renderer's `dumpsys meminfo`; Apple if a runner is at hand. Record the figures in `design.md` (Open Questions) and say whether a cap changes.
- [ ] 8.2 Drop TAB-023 to TAB-028 from `openspec/unverified.tsv` as their checks land; `test/js/spec_verification.test.js` green.
- [ ] 8.3 CLAUDE.md map rows for `RuntimeVars` (`loaded`), `WebViewTabBinding` and `ActivationTable`; the `indicesToEvictForLruCap` paragraph in `openspec/specs/webspaces/spec.md`. Verify: `node tool/spec_map.js` lists every new id with a check.

## Workflow follow-up

- Archive `inactive-tabs` before this change: its deltas modify TAB-002, TAB-003 and TAB-011, which only exist once that change is archived.
- Then archive `warm-tabs` and run `npx openspec validate --no-interactive --all`.
