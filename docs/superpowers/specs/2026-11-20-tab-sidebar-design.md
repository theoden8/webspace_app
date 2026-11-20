# Site navigation: site strip with tabs, and a tab sidebar

Status: draft for approval. Every decision below was settled with the user on
the clickable prototype beside this file
([tab-sidebar-prototype.html](tab-sidebar-prototype.html)); each is marked as
the user's call or the designer's.

## Intent

The user wants their tabs in view, not behind a sheet. On a wide desktop
window that means a sidebar down the left, as Firefox's vertical tabs: every
site of the webspace with its tabs under it, collapsible to a rail and
hideable. On a phone, a thin rail that stays docked, opening into a drawer.
The site strip, which today lists only sites, gains tabs too, so it becomes
the horizontal alternative to the sidebar rather than something beside it.

Today a site's tabs are reached only through the Tabs sheet (TAB-008), a
bottom sheet over the page that closes on every pick.

## Goals

- One setting, **Site navigation**: **Tab button** (the default, today's behaviour), **Site strip** or
  **Sidebar**. The strip and the sidebar never show together.
- **Site strip**: as today, a row of site chips at the top or bottom; a
  site's chip opens out sideways to show that site's tabs.
- **Sidebar**: the webspace's sites and tabs down the left, in three states
  on every width: open, collapsed to a rail, hidden. Open, it shows a **tab
  tree** or **squares** (the default), in either design.
- **In full screen**: one three-way choice for whichever is chosen: Hidden,
  Kept, or Button (a small accessory brings it back).
- The **legacy design** gets the same choice; its open sidebar keeps its
  squares.
- "Tab strip" is renamed **site strip** everywhere the user reads it.

## Non-goals

- A sidebar on the right-hand side.
- Anything the Tabs sheet cannot do today: the strip and the sidebar show
  the same tabs and act on them the same way, in different places.
- Changing the library's own tab view (WEBSPACE-004), which stays the sheet.

## Anti-goals

- A second implementation of a tab action. Closing, moving, undoing and
  opening a tab go through `TabsController` from every surface; if one
  surface behaves differently, the change failed.
- A full-width sidebar docked on a phone.
- A drawer or swipe that takes Android's back gesture.
- A layout change for anyone on upgrade: the default is Tab button, today's behaviour.

## Approaches

| Approach | What it is | Outcome |
|---|---|---|
| A. "Side" as a third strip position | Top, Bottom or Side for the site strip; Side swaps the strip for the tree | Rejected by the user at first: one setting looked like it hid the sidebar inside the strip's settings |
| B. A separate Tab sidebar switch | The strip keeps its settings; the sidebar is on or off beside it | Chosen first, then outgrown: each new case needed a rule to stop the strip and the sidebar clashing (hide the strip while the sidebar shows, replace the strip's button) |
| **C. One Site navigation choice** | **Tab button, Site strip or Sidebar, the last two showing tabs; one full-screen choice for either** | **Chosen by the user** once the strip gained tabs, which made the two equals |

How it is built is common to every approach: one tab listing owned by
`TabsController`, drawn as rows (the tree: sidebar, drawer, Tabs sheet) or as
chips (the strip, the legacy squares' panels), each a single widget the
surfaces share.

## The settings

Under Behaviour, replacing today's strip rows (FS-009's Hidden / Pinned /
Button presentation, "Keep in full screen"):

```
Site navigation:       [ Tab button ]  [ Site strip ]  [ Sidebar ]
  Site strip position: [ Top ]  [ Bottom ]                    (strip only, FS-012)
  Open sidebar shows:  [ Squares ]  [ Tab tree ]            (sidebar only, Squares)
  Expand rail on hover: on / off                              (sidebar only, off)
In full screen:        [ Hidden ]  [ Kept ]  [ Button ]       (not with Tab button)
```

- **Tab button** is the default, in both designs (the user's call). It was
  first called Off; renamed because the tab-count button still reaches the
  tabs (the user's call).
- **Tab button**: no strip, no sidebar. The app bar's tab-count button opens the
  Tabs sheet; a second tap closes it. This is the only mode with that
  button.
- **In full screen** (with Tab button, full screen shows no navigation, as
  today; a floating tab-count button there is a possible follow-up):
  - Hidden: nothing shows;
  - Kept: the strip or the sidebar stays as it is;
  - Button: the strip's round button (it reveals the strip, whose cross puts
    it away), or the sidebar's arrow tab (below).
- The sidebar's state is **one for the app** (the user's call), not one per
  webspace, and is remembered across restarts.

## Site strip with tabs

- The site on screen's chip is open, showing its tabs after it; any other
  chip opens or closes by a small arrow on it, without switching site. A
  second tap on the site on screen's chip closes it. A closed chip shows its
  tab count.
- On a phone **one site's tabs are open at a time** (the user's call):
  opening one closes the others. A wide window may keep several open.
- Tabs are chips in the order they were opened. One row cannot nest, so a
  tab opened from another carries a small dot. A tap switches to it; its
  cross (on hover; a swipe on a phone is the builder's call) closes it; +
  at the end adds one.
- The strip scrolls sideways and keeps the tab on screen in view.
- The app bar has no tab-count button (the user's call). The three-dot site
  menu gains **All tabs**, which opens the Tabs sheet for what the strip
  cannot show: the nesting and the tabs other sites opened from here
  (TAB-017).

## Sidebar

### The tree

- The listing the Tabs sheet shows for the site on screen
  (`TabsController.sheetListing()`): the webspace's sites, then, under
  "Opened from here", the other sites whose tabs the active branch runs as
  (TAB-017), with the sheet's folding and its "N more" row.
- A site with tabs off, or every site while tabs are off app-wide, is a
  single row; a tap opens it. This is a variant of the listing at its owner;
  the sheet's own listing is unchanged.
- Marked as the sheet marks them: the site on screen and its active tab
  highlighted, rows holding no webview faded (TAB-011), each row coloured by
  its container (TAB-018).
- A tap on a site opens it; on a tab, opens its site on that tab. Dragging
  moves a tab and its subtree (TAB-015) or reorders sites (TAB-016) where the
  webspace can be reordered. Closing keeps the sidebar up, with the sheet's
  undo (TAB-022). + on a site's row adds a tab (on hover on a wide window,
  always on a phone); a tab's cross shows on hover, a swipe closes it on a
  phone.
- A site folds open or shut; the site on screen unfolds when it comes on
  screen. **A tab with tabs opened from it folds too** (the user's call): an
  arrow before its name, and folded it shows how many it holds (+2).
  Opening a tab inside a folded subtree unfolds the way to it.

### Squares (the user's call)

The open sidebar's default style, in both designs: the site grid of the
legacy drawer, a site's tabs as chips in a panel under its row, pointing at
its square, opening the way the strip's chips do (the site on screen open,
any other by the arrow in its square's corner, several at once on a wide
window, one at a time on a phone). Tabs are flat, in opener order, a dot
marking one opened from another; + adds one. The rail, the hidden state and
every control are the same as with the tree.

Squares are the default in both designs (the user's call); the tab tree is
the other choice.

### States, on every width (the user's call)

| | Wide window | Phone |
|---|---|---|
| Open | Docked on the left, from under the app bar to the bottom; the page and the URL bar beside it. Width set by dragging its right edge, remembered | The full sidebar as a drawer over the page; the rail stays under it |
| Collapsed | A 60px rail docked on the left | A 52px rail docked on the left |
| Hidden | Nothing docked | Nothing docked |

The rail: one icon per site with its tab count as a badge; under the site on
screen, one stripe per tab, the active one dark; a tap on a stripe switches
tab. With "Expand rail on hover" on, hovering the rail slides the names out
over the page without resizing it.

Turning the sidebar on starts it open on a wide window and at the rail on a
phone; moving to a narrow window starts at the rail.

### Controls (the user's calls, settled on the prototype)

| Control | Where | Does |
|---|---|---|
| Collapse button (the sidebar icon, not a cross) | Top right of the open sidebar and of the drawer | Collapses to the rail. In the full-screen sidebar, puts it away |
| Expand button (the sidebar icon) | Top of the rail | Opens the sidebar (the drawer on a phone) |
| Cross | Bottom of the rail only | Hides the sidebar |
| Sidebar icon in the app bar | Top left, **only while the sidebar is hidden** | Opens it fully, never to the rail |
| Arrow tab | Left edge, **only while the sidebar is closed** (hidden; in full screen with Button, put away) | Tap: back as it was left. Drag right: the sidebar follows the finger, the page following its width, and on release settles at the nearest of hidden, the rail and open (closed or open for the drawer and the full-screen sidebar). Drag up or down: moves along the edge, remembered |
| Keyboard shortcut | | Cycles open, collapsed, hidden (a new `KeyboardShortcut` case, NAV-014) |

- On a phone the drawer also closes on a pick, a tap outside it, or Back,
  dropping back to the rail.
- On Android with gesture navigation the arrow tab claims the system back
  gesture over its own height only (a system-gesture exclusion rect, well
  inside Android's 200dp limit), so its drag works; Back stays everywhere
  else on that edge (designer's call; the user was offered tap-only and an
  inset tab).
- The left-edge swipe never opens anything while a page is on screen:
  Android's back gesture owns that edge (`drawerEdgeDragWidth` is 0 over a
  page today). The arrow tab's drag is how a finger pulls it out.
- With the sidebar open or collapsed the app bar is as it is today: the
  Alternative design's webspaces button at the top left.
- Flutter's `Icons.view_sidebar` draws its panel on the right; it is
  mirrored so the panel shows on the left.

### Full screen

- Hidden: no sidebar, rail or arrow tab.
- Kept: the sidebar stays in its state; hidden, the arrow tab shows.
- Button: the sidebar is put away for as long as full screen lasts and the
  arrow tab shows; a tap or a drag right shows the open sidebar over the
  page without resizing it, until its collapse button or a pick puts it
  away. Leaving full screen restores the state it had.
- The strip's button and the arrow tab count as the app's own controls for
  FS-011, so swiped-in system bars are inset around them.
- Inside the frame, full screen is entered and left as today: a double tap
  on the site's name or the site menu's Full screen; the handle at the top
  centre or Back.

## Legacy design (the user's calls)

- **Tab button**: as today. The menu button opens `SiteDrawer`, the sites as a
  grid with Back to webspaces and Add site.
- **Site strip**: as in the Alternative design, beside today's drawer.
- **Sidebar**: the sidebar replaces the drawer and keeps the legacy look:
  - its header (the WebSpace logo, the webspace's name, Back to webspaces)
    and its Add site button frame it;
  - **open, it shows the squares** by default (above), so it looks like the
    drawer it replaces;
  - the rail and the hidden state are as in the Alternative design;
  - the legacy design has no launcher, so its app bar gets no webspaces
    button; while the sidebar is hidden the menu button's place holds the
    sidebar icon.
- Back to webspaces also stays in the three-dot site menu
  (`SiteMenuAction.backToWebspaces`) in both designs.

## Which way in opens what

One pure decision; its output is a sealed type with one case per surface.

| Way in | Tab button | Site strip | Sidebar, wide | Sidebar, phone |
|---|---|---|---|---|
| App-bar tab-count button | Tabs sheet, second tap closes | not shown | not shown | not shown |
| Tap on the site on screen's chip | (no strip) | opens or closes its tabs | (no strip) | (no strip) |
| Site menu: All tabs | not shown | Tabs sheet | Tabs sheet | Tabs sheet |
| Sidebar keyboard shortcut | none | none | cycles states | cycles states |
| App-bar sidebar icon (hidden only) | | | opens fully | opens the drawer |
| Arrow tab (closed only) | | | back as it was | back to the rail; drag: the drawer |
| Library tab-count button (no site on screen) | Tabs sheet | Tabs sheet | Tabs sheet | Tabs sheet |

The strip, the sidebar, the rail and the arrow tab show only while a site is
on screen, as the strip does today. A locked kiosk session shows none of them
(KIOSK-002).

## Motion

The app's own `Motion` timings (`lib/theme/design_tokens.dart`), as the
prototype plays them:

| Change | Duration | Curve |
|---|---|---|
| Sidebar opens, collapses, expands, hides (its width, over the page; the page resizes when it ends) | 420ms (`layoutMorph`) | emphasized |
| Site strip leaves or returns | 250ms (`settle`) | emphasized |
| A chip or a square opening out its tabs | 250ms | emphasized |
| Drawer, full-screen sidebar, Tabs sheet sliding in / out | 250ms / 200ms | emphasized decelerate / accelerate |
| Rows unfolding, a new tab appearing / folding, a closed tab collapsing | 250ms / 200ms | emphasized / emphasized accelerate |
| Fold arrows turning | 200ms | emphasized |
| The arrow tab sliding in, or to a new height | 180ms (`lift`), 250ms | emphasized decelerate |
| The page switching site or tab | 180ms fade (`reveal`) | linear |

The sidebar's contents keep their width while it narrows, so nothing
reflows mid-animation. With reduced motion asked for, every change is
immediate.

## Rename: tab strip to site strip

- Every user-facing "tab strip" or "tab bar" naming the strip becomes "site
  strip"; the ARB keys are renamed in all 67 locales and each locale gets
  the term in its own language, translations in their own commit.
- Code names follow: `SiteTabStrip` to `SiteStrip`, `TabStripEdge` to
  `SiteStripEdge`, and what is named after them.
- Specs' prose follows; requirement ids keep their numbers.
- The rename lands first, on its own, so the new strings use the new name.

## Constraints from the codebase

- **One owner per tab action and per listing**: `TabsController`. The Tabs
  sheet's list becomes the tree widget the sheet, the sidebar and the drawer
  share; the strip's tab chips and the legacy squares' panels share one chip
  widget. `SiteDrawer` stays for the legacy design with navigation Tab button or
  Strip; the legacy sidebar's grid grows from it rather than beside it.
- **The surface decision is a pure engine** over the navigation choice, the
  full-screen choice, whether full screen is on, the sidebar's state, the
  window's width, kiosk lock and whether a site is on screen (CLAUDE.md rule
  4), with a boundary test.
- **Settings are `AppPref` entries**: site navigation, the full-screen
  choice, the open sidebar's style, the sidebar's state, its width, expand on hover, the arrow tab's
  height. Each carries backup, demo mode and the live value.
- **Existing installs keep their layout.** Today's strip prefs
  (`showTabStrip`, `tabBarButton`, `tabStripInFullscreen`) are read once,
  on the first launch that knows the new prefs, into site navigation and the
  full-screen choice, as `loadLegacyDesign` decides the design once; the old
  keys are then declared retired with their reason. Saved strip keys that
  stay (`tabStripEdge`) keep their names.
- **Removing the tab-count button** outside Tab button removes one way to open a
  new tab; the strip's and the tree's + take that job.
- **Specs**: the strip-with-tabs and sidebar requirements go in the
  `inactive-tabs` change as new TAB-* ids; FS-009 and FS-007 are rewritten
  for the three-way full-screen choice; each requirement is named by the
  check that verifies it.
- **Design gallery**: the sidebar in both styles, the rail and the strip
  with tabs get gallery cards; every new UI file compiles for web
  (DESIGN-001).
- **Files stay under 2000 lines**: `webspace_page.dart` is at 1983, so the
  new layout lives in its own files.

## Calls made by the designer

- The tab-count button's job outside Tab button goes to the strip, the tree and
  the site menu's All tabs.
- Today's strip "Button" presentation out of full screen has no place in
  the three-way choice. An install on it maps to Site strip with In full
  screen set to Button; its strip is then pinned out of full screen (the
  user's call: strip users get Site strip).
- The full-screen sidebar overlays the page instead of resizing it.
- Expand rail on hover is kept, off by default, as in Firefox.
- **Legacy design with no site on screen.** The legacy drawer is the only
  list of a webspace's sites, opened right after a webspace is picked
  (`WebspacesController.select`), by the menu button, and by NAV-009's Back.
  Under Sidebar the legacy sidebar therefore shows whenever a webspace is
  selected, a site on screen or not, and those three open it (open on a wide
  window, the drawer on a phone). The Alternative design keeps the rule that
  it shows only while a site is on screen.
- **NAV-009 under Sidebar.** Back at the start of a site's history opens the
  sidebar: open on a wide window, the drawer on a phone.
- **All tabs under Sidebar too.** The site menu's All tabs opens the Tabs
  sheet in Site strip and in Sidebar mode, so the nesting, drag-to-nest
  (TAB-015) and the tabs other sites opened (TAB-017) stay reachable when the
  sidebar shows squares, which list tabs flat.
- **The page does not resize every frame.** Resizing the webview each frame
  is costly and risks blank surfaces on Android (BUG-001, BUG-002). While the
  sidebar's width animates it slides over the page; the page takes its new
  width once, when the motion ends, through the surface-repaint path. The
  edge drag shows a guide line and resizes on release.

## Left to the builder

- The width threshold between wide and phone layouts, and the sidebar's
  default, minimum and maximum widths.
- The keyboard shortcut's keys, free in every `KeyConvention`.
- How the tree, chip and surface widgets are split into files and named.
- The wording and numbering of the new TAB-* requirements.
- The order of commits after the rename.
