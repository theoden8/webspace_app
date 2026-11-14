# Tasks

Builds on `inactive-tabs` (the tab model and hosted tabs). Requirements:
TAB-002, TAB-003, TAB-011 (modified), TAB-023 to TAB-028, PAUSE-006,
CONT-003. Design: `design.md`.

## 1. The model first

- [x] 1.1 `formal/retention.tla`: the warm views ranked before the sites (design D2); a demonstrator that evicts a site's active webview while a warm tab of another site is loaded, which TLC rejects (TAB-024); `retention_activefirst.cfg`; `formal/proofs/retention_safety.tla` holds `Inv_WarmFirst`.
- [x] 1.2 The costliest tab world before the change: `activation_gen_jar_cold_tabs_reset_one`, 15,094 worker-seconds on CI's master run.
- [x] 1.3 `formal/activation.tla` through the tables and the printer (design D5, shape B): `built` and `hist` unchanged; `warm` a `ModelVar` over `Tabbed`, its leaf `WebViewModel.warmViews`; `WarmTabs`, `WarmUnits`, `WarmOver` printed `Def`s; `Inv_WarmShown`, `Inv_WarmListed`, `Inv_WarmLoaded`, `Inv_WarmOneSite`, `Inv_WarmLimit`, `Inv_ViewsCapped`; mutants `warmnolimit`, `warmanysite`, `closekeepswarm`, `capignoreswarm`, each caught, each driven by a script in `test/planted_mistakes_test.dart`; worlds `tabs_warm_one`, `tabs_cap_two`.

## 2. Webviews as the residency unit

- [x] 2.1 The order is `SiteUnloadEngine.inDropOrder` over `WarmUnit`s, not new retention tiers (design D2). Verify: `test/warm_tabs_test.dart`, TAB-024.
- [x] 2.2 The cap counts sites and warm views (CONT-003): `warmToDropForCap`, and the activation's plan drops the warm views it needs beside the sites it picks. Verify: `test/warm_tabs_test.dart`, TAB-024; `Inv_ViewsCapped` on `tabs_cap_two`.
- [x] 2.3 Memory pressure takes one warm view an event before any site (`pplan`'s `disposed` branch).
- [x] 2.4 `RuntimeVars.loaded` stays a set of sites; the count reads `WarmUnits(loaded)`. Verify: `./formal/trace/check_steps.sh`.

## 3. The switch

- [x] 3.1 `SiteViews` (`lib/web_view_model_site_views.dart`) owns the shown view and the warm ones; `WebViewTabBinding.built` stays the shown view's tab, bytes tagged as before (TAB-003, BUG-036). Verify: `test/warm_tabs_test.dart`; the tab schedules.
- [x] 3.2 `TabTable`'s `tRebind`: the tab left goes warm unless the limit, the cap or a joining site's plan needs its room (`WarmOver`, `KeepsWarm` with the pick on its arm); a warm target shown as it is. Verify: the tab schedules, `check_steps.sh`.
- [ ] 3.3 The costliest tab world after: 3 h 01 min on three CI workers (about 32,600 worker-seconds, 41,235,526 distinct states), about twice 1.2's 15,094. Every tab world runs the shipped limits, which in a three-tab world let both inactive tabs be warm; the next step is the printed worlds at a limit of one, the shipped limits kept in `tabs_cap_two`.

## 4. A warm tab acts as nothing

- [x] 4.1 Going warm pauses the view itself, not through `pauseWebView`, so a notification or background-audio site's warm view pauses too (design D6). Verify: `test/warm_tabs_test.dart`, TAB-025.
- [x] 4.2 Going warm ends the page's camera and microphone (`stopCaptureScript`), its media, and the screen share and player the shown view spoke for (`_shownGone`). Verify: `test/warm_tabs_test.dart`, TAB-025.
- [x] 4.3 The notification bridge drops a post from a view that is not shown (`WebViewConfig.speaksForSite`). Verify: `test/warm_tab_notification_test.dart`, TAB-025.

## 5. Running identity and unloads

- [x] 5.1 Per slot instead of per view (design D3, D8): a slot keeps warm only views running as its shown tab's site, so the existing judgment of the slot covers them, and an unload takes every view of the slot. Verify: `Inv_WarmOneSite` (`warmanysite`); `test/warm_tabs_test.dart`, TAB-027.
- [x] 5.2 Legacy shared jar: the unload lets go of all the slot's views in one dispose, before the jar's capture, as it let go of one.

## 6. The slot and the tab list

- [x] 6.1 Each view under a `GlobalKey` `KeyedSubtree`; warm views drawn `Offstage` under `TickerMode` off in the slot (`SiteWebViewStack`), so a warm view shown again keeps its element.
- [x] 6.2 The Tabs sheet counts a warm tab as loaded, and only the active tab as on screen (TAB-011). Verify: `test/tabs_sheet_test.dart`.

## 7. Persistence

- [x] 7.1 Every switch captures the tab it leaves (`tCap`, `tCapSave`) before `tRebind` keeps it warm, and a warm view goes with no capture (TAB-028). Verify: `test/warm_tabs_test.dart`, TAB-028; the tab schedules replay the order.

## 8. Measure and document

- [ ] 8.1 Android: N tabs of one site against N sites on the emulator, the renderer's `dumpsys meminfo`; Apple if a runner is at hand. Record the figures in `design.md` (Open Questions) and say whether a cap changes.
- [x] 8.2 TAB-023, TAB-024, TAB-025, TAB-026, TAB-027 and TAB-028 dropped from `openspec/unverified.tsv`.
- [x] 8.3 A CLAUDE.md map row for `SiteViews`.

## Workflow follow-up

- Archive `inactive-tabs` before this change: its deltas modify TAB-002, TAB-003 and TAB-011, which only exist once that change is archived.
- Then archive `warm-tabs` and run `npx openspec validate --no-interactive --all`.
