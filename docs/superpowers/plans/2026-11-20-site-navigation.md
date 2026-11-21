# Site Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Site navigation choice (Tab button, Site strip, Sidebar), a site strip whose chips open out to show tabs, and a tab sidebar (squares or tree) with open, rail and hidden states on every width, in both designs.

**Architecture:** One pure engine decides which surfaces show from the settings and the page's state; one controller owns the sidebar's state; the tab listing stays owned by `TabsController`, drawn as rows (`TabTree`, shared with the Tabs sheet) or as chips (`TabChips`, shared by the strip and the squares). The page composes them through one layout widget so `webspace_page.dart` stays under 2000 lines.

**Tech Stack:** Flutter 3.44.9 (Dart), `AppPref`, the app's `Motion` tokens, ARB l10n, OpenSpec.

**Spec:** [docs/superpowers/specs/2026-11-20-tab-sidebar-design.md](../specs/2026-11-20-tab-sidebar-design.md); behaviour reference: [tab-sidebar-prototype.html](../specs/tab-sidebar-prototype.html).

## Global Constraints

- CLAUDE.md governs: layers point down, engines pure (no Flutter import), named parameters past the first, no `catch (_)`, no file over 2000 lines, `unawaited` for dropped futures.
- Tooling: `fvm` is not installed here; `/root/flutter-3.44.9` matches `.fvmrc`. Run `export PATH=/root/flutter-3.44.9/bin:$PATH` and use `flutter` / `dart` where CLAUDE.md says `fvm flutter` / `fvm dart`. Run `dart tool/gen_l10n.dart` after any ARB change before tests.
- Default Site navigation is **Tab button** in both designs; nobody's layout changes on upgrade.
- Sidebar state is one for the app, remembered across restarts.
- Open sidebar style defaults to **Squares** in both designs.
- Rail widths: 60 px wide window, 52 px phone. Phone drawer width 290 px. Sidebar width default 260, min 200, max 420.
- Phone: one site's tabs open at a time (strip and squares). Wide: several.
- Arrow tab shows only while the sidebar is closed; app-bar sidebar icon only while it is hidden and opens it fully; collapse button (sidebar icon) at the open sidebar's top right; cross only at the rail's bottom.
- Motion: sidebar width 420 ms `Motion.layoutMorph` emphasized; strip in/out and chip open 250 ms `Motion.settle`; drawers/overlay in 250 ms decelerate, out 200 ms accelerate; arrow tab 180 ms `Motion.lift`; page switch 180 ms `Motion.reveal`; reduced motion makes every change immediate.
- Translations ride their own commit after the code + `app_en.arb` commit (CLAUDE.md, Git).
- Saved key `tabStripEdge` keeps its name; `showTabStrip`, `tabBarButton`, `tabStripInFullscreen` are read once into the new prefs, then retired with reasons.
- A locked kiosk session shows no strip, sidebar, rail, arrow tab or drawer (KIOSK-002).

## Review Focus

- An existing install on today's strip Button mode (`tabBarButton` true) upgrades to Site strip with In full screen = Button; Pinned (`showTabStrip`) with `tabStripInFullscreen` to Kept, without to Hidden; nothing set to Tab button. Test in Task 2.
- An old backup file carrying only the retired strip keys imports to the same mapping. Test in Task 2.
- The window crossing the wide/phone threshold while the sidebar is open lands at the rail on the phone side and keeps the app-wide state otherwise. Test in Task 3.
- A site with tabs off, and tabs off app-wide, still lists in the sidebar and squares as a single row/tile that opens the site. Test in Task 5.
- Closing the last-but-one tab and the active tab from the sidebar, strip and squares goes through `TabsController` with the sheet's undo. Test in Task 6.

---

### Task 1: Rename tab strip to site strip

**Files:**
- Modify: `lib/widgets/site_tab_strip.dart` → rename to `lib/widgets/site_strip.dart` (class `SiteStrip`); `lib/settings/tab_strip_edge.dart` → `lib/settings/site_strip_edge.dart` (`SiteStripEdge`); every importer (`grep -rln "SiteTabStrip\|TabStripEdge\|tab_strip_edge\|site_tab_strip" lib test tool`).
- Modify: `lib/l10n/app_en.arb` (keys and values below), every `loc.<old>` call site.
- Modify: specs' prose ("tab strip" → "site strip") in `openspec/specs/*/spec.md` and `openspec/changes/*/` (not `archive/`).
- Rename tests: `test/tab_strip_edge_app_test.dart` → `test/site_strip_edge_app_test.dart`, `test/tab_strip_reveal_app_test.dart` → `test/site_strip_reveal_app_test.dart`.

**Interfaces:**
- Produces: `SiteStrip`, `SiteStripEdge { top, bottom }` with `SiteStripEdge.current` and `SiteStripEdge.of(stored, desktop:)`; page members `_siteStripShown`, `_siteStripEdge`, `_buildSiteStrip(at:)`; `FullscreenHost.siteStripEdge`; `FullscreenSystemUi.of(kioskLocked:, siteStripEdge:, floatingControl:)` (the `tabBarButton:` parameter renamed `floatingControl:` here, as Task 8 widens what it means).
- ARB renames (value in English): `appSettingsGroupTabStrip`→`appSettingsGroupSiteStrip` "Site strip"; `appSettingsSiteTabStrip`→`appSettingsSiteStrip` "Site strip"; `appSettingsSiteTabStripSubtitle`→`appSettingsSiteStripHint` "Show a bar with the webspace's sites"; `appSettingsFullscreenTabStrip`→`appSettingsFullscreenSiteStrip` "In full screen, site strip"; `appSettingsTabStripPosition*`→`appSettingsSiteStripPosition*`; `appSettingsFullscreenTabStrip{Hidden,Always,Button}`→`appSettingsFullscreenSiteStrip{…}`; `siteSettingsFullscreenHint` value says "site strip". Descriptions updated to say site strip.

- [ ] **Step 1:** Rename files, classes, members and ARB keys; update descriptions; `dart tool/gen_l10n.dart`.
- [ ] **Step 2:** Run `flutter test test/site_strip_edge_app_test.dart test/site_strip_reveal_app_test.dart test/fullscreen_system_bars_test.dart test/remote_tabs_test.dart` — expected PASS unchanged in behaviour.
- [ ] **Step 3:** Run `dart analyze --no-fatal-warnings` (0 errors) and `npm run test:js` (exit 0; `l10n_coverage` fails until Step 5, expected).
- [ ] **Step 4:** Commit code + `app_en.arb` + specs: `git commit -m "Rename the tab strip to the site strip"`.
- [ ] **Step 5:** Rename the keys in the other 66 `app_*.arb`, translating "site strip" in each locale; `npm run test:js` exit 0; commit `"Translate the site strip rename"`.

### Task 2: Site navigation settings and their migration

**Files:**
- Create: `lib/settings/site_navigation.dart`
- Modify: `lib/settings/app_prefs.dart`, `lib/main.dart` (startup load beside `loadLegacyDesign`), `lib/controllers/startup_controller.dart` (restore path), `lib/settings_import_engine.dart`, `test/js/prefs_key_history.test.js` (RETIRED), `test/settings_backup_compat_test.dart` (`_retiredKeys`), `tool/backup_compat/superset.json`
- Test: `test/site_navigation_test.dart`

**Interfaces:**
- Produces in `site_navigation.dart`:
  - `enum SiteNavigation { tabButton, strip, sidebar }`, `static SiteNavigation get current`
  - `enum FullscreenNavigation { hidden, kept, button }`, `static FullscreenNavigation get current`
  - `enum SidebarState { open, collapsed, hidden }`, `static SidebarState get current`
  - `enum SidebarStyle { squares, tree }`, `static SidebarStyle get current`
  - `({SiteNavigation navigation, FullscreenNavigation inFullscreen}) siteNavigationFrom({required bool showTabStrip, required bool tabBarButton, required bool tabStripInFullscreen})` (pure mapping)
  - `Future<void> loadSiteNavigation(SharedPreferences prefs)`: once, when `siteNavigation` is absent, writes the mapped values from the old keys.
- New `AppPref`s (section appearance): `siteNavigation` `'tabButton'`, `fullscreenNavigation` `'hidden'`, `sidebarState` `'open'`, `sidebarStyle` `'squares'`, `sidebarWidth` `260`, `sidebarExpandOnHover` `false`, `sidebarHandleY` `55` (percent of the body height). Remove `showTabStrip`, `tabBarButton`, `tabStripInFullscreen`.
- Import: `planSettingsImport` applies `siteNavigationFrom(...)` when a backup carries the old keys and not `siteNavigation`.

- [ ] **Step 1: Write the failing tests** in `test/site_navigation_test.dart`:
  - `'tab bar button maps to strip with button in full screen'`: `siteNavigationFrom(showTabStrip: false, tabBarButton: true, tabStripInFullscreen: false)` == `(navigation: SiteNavigation.strip, inFullscreen: FullscreenNavigation.button)`.
  - `'pinned strip kept in full screen maps to kept'`: `(true, false, true)` → `(strip, kept)`; `(true, false, false)` → `(strip, hidden)`; `(false, false, false)` → `(tabButton, hidden)`; `(true, true, true)` → `(strip, button)` (button wins, as `TabStrip.current` does today).
  - `'loadSiteNavigation migrates once'`: prefs `{'tabBarButton': true}` → after load `AppPref.siteNavigation.value == 'strip'`, `fullscreenNavigation == 'button'`; a second load with `siteNavigation` already `'sidebar'` leaves it.
  - `'an old backup imports its strip choice'`: a plan from a backup map `{'showTabStrip': true, 'tabStripInFullscreen': true}` writes `siteNavigation: 'strip'`, `fullscreenNavigation: 'kept'`.
- [ ] **Step 2:** `flutter test test/site_navigation_test.dart` → FAIL (file missing).
- [ ] **Step 3:** Implement the enums, mapping, prefs, startup load and import mapping; retire the three keys with the reason `'read once into siteNavigation and fullscreenNavigation (site navigation design, 2026-11-20)'`; add the new prefs to `superset.json`.
- [ ] **Step 4:** `flutter test test/site_navigation_test.dart test/app_prefs_test.dart test/settings_backup_test.dart test/settings_backup_compat_test.dart` and `node --test test/js/prefs_key_history.test.js` → PASS.
- [ ] **Step 5:** Commit `"Read the strip prefs into one site navigation choice"`.

### Task 3: Navigation surface engine

**Files:**
- Create: `lib/services/navigation_surface_engine.dart`
- Test: `test/navigation_surface_engine_test.dart`

**Interfaces:**
- Produces:
  - `typedef NavigationQuery = ({SiteNavigation navigation, FullscreenNavigation inFullscreen, bool fullscreen, SidebarState sidebar, bool wide, bool kioskLocked, bool siteOnScreen, bool revealed})` (`revealed`: the full-screen accessory has shown its strip or sidebar)
  - `enum SidebarDock { none, rail, full }`, `enum SidebarFloat { none, drawer, overlay }`
  - `typedef NavigationSurfaces = ({bool strip, SidebarDock dock, SidebarFloat float, bool arrowTab, bool appBarSidebarIcon, bool tabCountButton, bool stripButton})`
  - `NavigationSurfaces navigationSurfaces(NavigationQuery q)`
  - `SidebarState settleSidebar({required double visible, required double width, required double rail})` → nearest of hidden (0), collapsed (rail), open (width)
  - `SidebarState sidebarOnNarrowing(SidebarState state)` → `open` becomes `collapsed`, others unchanged.

- [ ] **Step 1: Write the failing tests**, one per row of the spec's tables, e.g.:
  - `'tab button shows only the tab count'`: `(tabButton, hidden, fullscreen: false, …)` → `strip: false, dock: none, float: none, tabCountButton: true`.
  - `'strip out of full screen'` → `strip: true, tabCountButton: false`; `'strip, full screen, button'` → `strip: false, stripButton: true`; with `revealed: true` → `strip: true, stripButton: false`; `kept` → `strip: true`.
  - `'sidebar wide open'` → `dock: full, arrowTab: false, appBarSidebarIcon: false`; collapsed → `dock: rail`; hidden → `dock: none, arrowTab: true, appBarSidebarIcon: true`.
  - `'sidebar phone open'` → `dock: rail, float: drawer`; collapsed → `dock: rail, float: none, arrowTab: false`; hidden → `arrowTab: true, appBarSidebarIcon: true`.
  - `'sidebar full screen button'` → `dock: none, arrowTab: true`; revealed wide → `float: overlay, arrowTab: false`; revealed phone → `float: drawer`; `kept` → dock as out of full screen; `hidden` → nothing.
  - `'no site on screen or kiosk shows nothing'` for each navigation.
  - `settleSidebar(visible: 50, width: 260, rail: 60)` == `collapsed`; `visible: 10` == `hidden`; `visible: 200` == `open`. `sidebarOnNarrowing(SidebarState.open)` == `collapsed`.
- [ ] **Step 2:** `flutter test test/navigation_surface_engine_test.dart` → FAIL.
- [ ] **Step 3:** Implement as exhaustive `switch`es on the enums, no `default`; no Flutter import (`engine_impure` lint).
- [ ] **Step 4:** Test → PASS; `dart analyze --no-fatal-warnings` 0 errors.
- [ ] **Step 5:** Commit `"Decide the navigation surfaces in one engine"`.

### Task 4: Sidebar controller and the open-sites rule

**Files:**
- Create: `lib/controllers/sidebar_controller.dart`, `lib/services/open_sites.dart`
- Test: `test/sidebar_controller_test.dart`, `test/open_sites_test.dart`

**Interfaces:**
- Produces:
  - `class SidebarController` over `AppPref.sidebarState`: `collapse()`, `expand()`, `hide()`, `openFully()` (always `open`), `restore()` (the state before `hide`, default `open`), `cycle()` (open → collapsed → hidden → open), `settle(SidebarState to)`, `narrowed()` (applies `sidebarOnNarrowing`), `SidebarState get state`.
  - `class OpenSites` (immutable): `bool isOpen(SiteId id, {required SiteId? current})`, `OpenSites toggle(SiteId id, {required SiteId? current, required bool single})`, `OpenSites onSwitch({required SiteId to, required bool single})`. The site on screen is open unless shut; with `single`, opening one closes every other, the site on screen included.
- [ ] **Step 1: Write the failing tests:** `'restore returns to the rail it was hidden from'` (collapse, hide, restore → collapsed); `'openFully ignores the rail'` (collapse, hide, openFully → open); `'cycle'`; `OpenSites`: `'phone opens one at a time'` (current docs; toggle mail single → mail open, docs not; toggle chat → only chat); `'wide keeps several'`; `'second tap on the current site closes it'`.
- [ ] **Step 2:** Run both test files → FAIL.
- [ ] **Step 3:** Implement; `SidebarController` writes through `AppPref.sidebarState.set(name)`.
- [ ] **Step 4:** Tests → PASS.
- [ ] **Step 5:** Commit `"Own the sidebar's state and the strip's open sites"`.

### Task 5: Sidebar listing and the shared tab tree

**Files:**
- Create: `lib/widgets/tab_tree.dart` (the rows half of `TabsSheet`: trees, folding of sites and subtrees, drag, close with undo, the TAB-017 other trees)
- Modify: `lib/widgets/tabs_sheet.dart` (chrome only, hosts `TabTree`), `lib/controllers/tabs_controller.dart`
- Test: `test/tab_tree_test.dart`; existing `test/tabs_sheet_test.dart`, `test/tabs_sheet_app_test.dart` stay green unchanged

**Interfaces:**
- Produces:
  - `TabsController.sidebarListing()` → `TabsSheetListing` whose `sites` hold every site of the webspace view (a site with tabs off included), then the TAB-017 others; `TabsSheetSite` gains `final bool tabsOn` (a site with tabs off lists as one row).
  - `class TabTree extends StatefulWidget` with the same callbacks as `TabsSheet` plus `required TabTreeDensity density` (`enum TabTreeDensity { sheet, sidebar, touch }`: row heights 40 / 28 / 48) and `required bool showsEveryTree` (the sidebar: no This site / All sites switch).
- [ ] **Step 1: Write the failing tests** in `test/tab_tree_test.dart`: `'a site with tabs off is one row that opens it'`; `'a tab subtree folds and shows its count'` (fold Q3 plan with two children → rows drop by 2, a `+2` label); `'opening a tab in a folded subtree unfolds the way to it'`; `'closing offers undo'` (close → `onCloseTab` called once, undo bar shown).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Move the row-building code out of `TabsSheet` into `TabTree` unchanged in behaviour, add `density` and `showsEveryTree`, add `sidebarListing()` and `tabsOn`.
- [ ] **Step 4:** `flutter test test/tab_tree_test.dart test/tabs_sheet_test.dart test/tabs_sheet_app_test.dart` → PASS; both files under 2000 lines.
- [ ] **Step 5:** Commit `"Share the Tabs sheet's tree with the sidebar"`.

### Task 6: Tab chips and the site strip with tabs

**Files:**
- Create: `lib/widgets/tab_chips.dart`
- Modify: `lib/widgets/site_strip.dart`, `lib/widgets/site_menu.dart` (`SiteMenuAction.allTabs`), `lib/screens/webspace_page.dart` (strip wiring, `OpenSites` state, All tabs, tab-count only for Tab button)
- Test: `test/site_strip_tabs_test.dart`

**Interfaces:**
- Consumes: `OpenSites` (Task 4), `navigationSurfaces` (Task 3).
- Produces: `TabChips(site:, isCurrent:, onOpenTab:, onCloseTab:, onNewTab:, compact:)` (flat opener order; a dot on a tab opened from another; cross on hover, swipe up to close on touch); `SiteStrip` gains `required OpenSites open`, `required ValueChanged<SiteId> onToggleOpen`, and tab callbacks.
- [ ] **Step 1: Write the failing tests:** `'the site on screen shows its tabs'`; `'a second tap on the site on screen closes them'`; `'the arrow opens another site without switching'`; `'a phone keeps one open'`; `'a closed chip shows its count'`; `'tab count button only with Tab button'`; `'the site menu offers All tabs with the strip'` and its tap opens the Tabs sheet; `'closing a tab from a chip goes through TabsController with undo'`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement; chip open/close animates width over `Motion.settle`.
- [ ] **Step 4:** Run with `test/site_strip_edge_app_test.dart test/remote_tabs_test.dart test/site_menu_app_test.dart` → PASS.
- [ ] **Step 5:** Commit `"Open a site's tabs in the site strip"`.

### Task 7: Sidebar surfaces and layout

**Files:**
- Create: `lib/widgets/site_sidebar.dart` (open panel: collapse button top right, `TabTree` or squares), `lib/widgets/sidebar_rail.dart` (icons, badges, per-tab stripes, expand on top, cross at bottom, expand-on-hover flyout), `lib/widgets/sidebar_squares.dart` (`SiteGridTile` grid with `TabChips` panels under each open site's row, pointing at its tile), `lib/widgets/sidebar_arrow_tab.dart` (tap, drag right with the panel following, drag up/down), `lib/widgets/site_navigation_frame.dart` (dock + main + floats + arrow tab, animations)
- Modify: `lib/screens/webspace_page.dart` (body through `SiteNavigationFrame`; app-bar sidebar icon; drawer and overlay), `lib/services/keyboard_shortcuts.dart` (`ToggleSidebar`), `lib/controllers/keyboard_shortcut_controller.dart`
- Test: `test/site_sidebar_app_test.dart`, `test/keyboard_shortcut_test.dart`

**Interfaces:**
- Consumes: `navigationSurfaces`, `settleSidebar` (Task 3); `SidebarController`, `OpenSites` (Task 4); `TabTree`, `sidebarListing` (Task 5); `TabChips` (Task 6).
- Produces: `SiteNavigationFrame({required NavigationSurfaces surfaces, required Widget main, required SidebarController sidebar, required WidgetBuilder panel, required WidgetBuilder rail, …})`; `final class ToggleSidebar extends KeyboardShortcut` (keys: builder's choice, free in every `KeyConvention`, asserted unique by the existing table test).
- [ ] **Step 1: Write the failing tests** (wide 1200×800 and phone 360×740 surfaces): `'wide: collapse to rail, cross hides, app-bar icon opens fully'`; `'wide: arrow tab shows only hidden; drag to 50 px settles at the rail'`; `'phone: rail docked at 52, expand opens the drawer, a pick drops back to the rail'`; `'the site strip never shows with the sidebar'`; `'squares: the site on screen opens its panel; phone keeps one'`; `'resize by the edge is remembered between 200 and 420'`; `'ToggleSidebar cycles'`; `'reduced motion makes changes immediate'` (`MediaQuery.disableAnimations`).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement; `webspace_page.dart` stays under 2000 lines (`test/js/file_size.test.js`).
- [ ] **Step 4:** Run the new tests with `test/webspace_library_app_test.dart test/fullscreen_navigation_test.dart` → PASS.
- [ ] **Step 5:** Commit `"Add the tab sidebar: rail, open panel, drawer and arrow tab"`.

### Task 8: Full screen choice and the legacy design

**Files:**
- Modify: `lib/controllers/fullscreen_controller.dart` (`revealed` covers the strip and the sidebar overlay), `lib/services/fullscreen_system_ui.dart`, `lib/screens/app_behaviour.dart` (Site navigation, In full screen, Open sidebar shows, Expand rail on hover, Site strip position only with the strip, tab width only with the strip), `lib/screens/app_settings.dart` (summary), `lib/widgets/site_drawer.dart` (header and Add site as parts the legacy sidebar reuses), `lib/screens/webspace_page.dart` (legacy: drawer only for Tab button and strip; sidebar framed by the legacy header)
- Test: `test/fullscreen_system_bars_test.dart`, `test/site_strip_reveal_app_test.dart`, `test/legacy_sidebar_app_test.dart`, `test/app_behaviour_navigation_test.dart`

**Interfaces:**
- Consumes: everything above.
- [ ] **Step 1: Write the failing tests:** `'full screen hidden shows nothing'`, `'kept keeps the sidebar docked'`, `'button: arrow tab reveals the sidebar over the page, collapse button puts it away, leaving restores'`; `FullscreenSystemUi.of` with the arrow tab or strip button as `floatingControl: true` → `barsHidden`; `'legacy sidebar keeps the header and Add site, squares by default, no webspaces button in the app bar'`; `'Behaviour shows the rows for the chosen navigation only'`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the four files plus `test/fullscreen_auto_app_test.dart test/kiosk*` → PASS.
- [ ] **Step 5:** Commit code + `app_en.arb` (`"Choose site navigation and what full screen keeps"`); then the 66 translations of the new keys (`"Translate the site navigation settings"`), `npm run test:js` exit 0.

### Task 9: Specs, design gallery, verification

**Files:**
- Modify: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md` (new TAB-* requirements: site navigation choice, strip with tabs, sidebar states and controls, squares, legacy sidebar, one-at-a-time on a phone), `openspec/specs/fullscreen-mode/spec.md` (FS-007/FS-009 rewritten for the three-way choice), `openspec/specs/app-settings/spec.md` (Behaviour rows), `openspec/unverified.tsv` only for ids no test names yet, `lib/design_gallery/main.dart` (cards: `site-strip-tabs`, `sidebar-squares`, `sidebar-tree`, `sidebar-rail`, `sidebar-drawer`)
- [ ] **Step 1:** Name each new requirement id in the test that checks it (rename test descriptions in Tasks 2 to 8 to carry the ids).
- [ ] **Step 2:** Run `npx openspec validate --no-interactive --all`, `node --test test/js/spec_verification.test.js`, `npm run design:check` → exit 0.
- [ ] **Step 3:** Full verification: `dart analyze --no-fatal-warnings` (0 errors), `flutter test` (exit 0), `npm run test:js` (exit 0). Read the exit status, not the last line.
- [ ] **Step 4:** Commit `"Specify site navigation and add its gallery cards"`; push; open the PR.
