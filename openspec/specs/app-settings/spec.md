# app-settings Specification

## Purpose
TBD - created by archiving change app-settings-categories. Update Purpose after archive.

## Requirements

### Requirement: APPSET-001 — App Settings is an index of categories

App Settings SHALL be a list of rows that each open a screen of their own, and
SHALL NOT edit any setting itself. The rows SHALL appear in this order, under
these headings:

- "App": Appearance, Behaviour.
- "Every site": Network, Privacy, User scripts.
- "Data": Backup and archives.
- "About": Developer while developer mode is on, otherwise App logs; then
  Licenses and Version.

Each category screen SHALL hold:

| Category | Rows |
|---|---|
| Appearance | app language; theme mode; accent colour |
| Behaviour | "Tab strip": the strip's mode, the full-screen choice while it is pinned, the tab width limit; "Opening and navigation": full screen on shortcut launch, back gesture opens the menu (where NAV-009 offers it), link handling; "Search" (LIR-029): Default search, the site search list |
| Network | "Outbound proxy": saved proxies, the app-wide proxy and its status, fields and connection test, the Tor status card (TOR-004); "Certificates" on Android and Linux (TLS-009) |
| Privacy | the protection report and the stats bar; "Trackers and ads": HTTPS upgrade, ClearURLs rules, the DNS blocklist and its level, the content blocker (a row opening its own screen), LocalCDN on Android; "What sites learn": the Firefox version, the timezone dataset, the location picker's map tiles; "Screen capture" where SCREENBLOCK-002 applies |
| Backup and archives | export, import, restore archive, close all archives while one is open (ARCH-001) |
| Developer | the developer-mode switch; "Logs": app logs, background log; "Experimental" (DEVTOOLS-011) |

#### Scenario: Nothing is edited on the index

**Given** the user opens App Settings
**Then** it shows no switch, slider, segmented button or text field
**And** the rows read Appearance, Behaviour, Network, Privacy, User scripts,
Backup and archives, App logs, Licenses and Version, in that order

#### Scenario: Developer mode trades the logs row for a category

**Given** developer mode is on
**When** the user opens App Settings
**Then** the About group shows a Developer row instead of App logs
**And** the Developer screen links the app logs

#### Scenario: Turning developer mode off leaves its screen

**Given** the Developer screen is open
**When** the user turns the developer-mode switch off
**Then** the screen closes
**And** App Settings shows the App logs row again

---

### Requirement: APPSET-002 — Each row says what its category is set to

Each category row SHALL carry a subtitle stating the category's state, so the
common question is answered without opening it. Where it names settings that
are on, it SHALL follow BEHAV-002: at most two names, then "{count} more", or
a fixed "nothing on" text. Subtitles are state-derived and so exempt from the
HINT-002 length cap.

- Appearance: the theme mode, then the chosen language when one overrides the
  system's.
- Behaviour: of the tab strip (when not hidden), full screen on shortcut
  launch, back gesture opens the menu and link handling, the ones on; or
  "Nothing enabled".
- Network: the app-wide route (the saved proxy's or gateway's name, the Tor
  route, or type and address), or "Default connection"; then the number of
  saved proxies when there are any.
- Privacy: of HTTPS upgrade, the DNS blocklist, the content blocker, LocalCDN
  and blocking screenshots, the ones in effect; or "No protection enabled".
- User scripts: how many global scripts are defined.
- Developer: the experiments switched on, or "Nothing enabled".
- Backup and archives: no subtitle. A count of archives would say whether any
  exist (ARCH-001).

#### Scenario: A change on a category screen shows on its row

**Given** Behaviour has nothing on
**When** the user turns on full screen on shortcut launch and goes back
**Then** the Behaviour row reads "Full screen on shortcut launch"

#### Scenario: More than two overflow

**Given** the tab strip is pinned, full screen on shortcut launch is on and
link handling is on
**Then** the Behaviour row names two of them and then "1 more"

---

### Requirement: APPSET-003 — Category screens apply at once

Every setting on a category screen SHALL apply and persist the moment it
changes, as on the single screen it replaces; there is no save step. A
category screen SHALL report each change through the callback App Settings
received from the main page, and App Settings SHALL keep its own copy current
from those reports for its summaries.

The app-wide proxy's text fields flush on editing complete, so the Network
screen SHALL prompt before it is left with an unflushed edit, and only the
Network screen: leaving any other category never asks.

Export, import and the archive actions SHALL run on the main page with App
Settings closed. The Backup screen SHALL return the chosen action; App
Settings SHALL then close its own route and run it.

#### Scenario: Export runs with settings closed

**Given** App Settings was opened from the main page
**When** the user opens Backup and archives and taps Export Settings
**Then** both screens close
**And** the export runs once, on the main page

#### Scenario: An unflushed proxy edit asks before leaving Network

**Given** the user typed a proxy address without submitting it
**When** they press Back on the Network screen
**Then** a discard prompt is shown
**And** App Settings itself never shows it

---

### Requirement: APPSET-004 — One tap, one action

A second tap that reaches a screen before what the first opened has laid out
over it SHALL do nothing. Every row on App Settings and its category screens
that opens a screen or a dialog SHALL be dropped while an earlier open from
the same screen is still in flight or while the screen is not the top route.
The Backup choice and the developer-mode switch SHALL pop only their own
route, once. The app-wide proxy SHALL save one change at a time, a change
made during a save being saved after it from the form as it then stands.
Back pressed again while the discard prompt is up SHALL NOT raise a second
prompt.

#### Scenario: A double tap opens a category once

**When** the user taps the Behaviour row twice before the screen has opened
**Then** one Behaviour screen is pushed
**And** one Back press returns to App Settings

#### Scenario: A double tap on Export stops at the main page

**When** the user taps Export Settings twice
**Then** the export runs once
**And** the page App Settings was opened from is still shown
