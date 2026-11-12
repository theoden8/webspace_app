## MODIFIED Requirements

### Requirement: TAB-002 - One container and one webview per site

Every tab of a site SHALL share the site's container and per-site posture,
except a hosted tab, which runs as its host (LIR-018). A tab SHALL be active,
warm or parked. A site's active tab SHALL be the one its slot shows; a warm
tab SHALL hold a live, paused webview that is not shown (TAB-023); no tab
SHALL hold more than one webview. A parked tab SHALL hold no controller, no
renderer and no native object; it SHALL consist of its `SiteTab` record and,
when it has navigation state worth keeping and `persistsNavState` is true, one
file `webview_state/<siteId>.<tabId>.enc`. The loaded-site caps and the
memory-pressure cascade SHALL count and pick webviews (PAUSE-006, PAUSE-012,
TAB-024).

#### Scenario: Memory pressure with many tabs

- **GIVEN** GitHub is on screen with one active tab, two warm tabs and four parked tabs, and Mastodon's active webview is the least recently used other webview
- **WHEN** the OS signals memory pressure
- **THEN** GitHub's least recently used warm tab is the one demoted, since warm tabs go before any active webview (TAB-024)
- **AND** Mastodon's webview and GitHub's parked tabs are untouched

#### Scenario: Parked tab costs nothing in memory

- **GIVEN** a site with twenty parked tabs
- **WHEN** the site's webview is evicted
- **THEN** exactly one capture runs (the active tab's)
- **AND** no parked tab is read, written or touched

---

### Requirement: TAB-003 - A tab switch is capture, dispose, rebuild, restore

Activating another tab of a site SHALL make it the tab the site's slot shows
and SHALL make the tab that was active warm (TAB-023). A warm target SHALL be
shown as it is, with no capture, dispose or reload. A parked target SHALL have
its saved bytes read, then in one turn, with no await between, become active
with its bytes queued for `onControllerCreated` when they exist, and get a
webview built for it. When the tab that was active cannot stay warm (the
caps, the warm limit or a mismatch unload take it), it SHALL be captured to
`<siteId>.<tabId>` when `persistsNavState` is true and disposed, as before.
Switching sites SHALL NOT change any site's active tab.

A webview SHALL show the history of the tab it was built for. Bytes queued
for a tab's webview SHALL carry the tab they were read for, and a webview
built for any other tab SHALL drop them. A capture SHALL store a webview's
bytes under the tab the webview was built for, and SHALL drop them when that
tab closed meanwhile. A capture whose save lands after its tab closed, or
moved to another site's key (LIR-024), SHALL remove the file it wrote.
Closing a site's last tab SHALL land it on a new tab at its home page, with an
id none of the site's tabs had: a capture of the closed tab still in flight
would otherwise land in the new tab's file. Gate: the switch, the close and the
duplicate are step tables (`TabTable.tabInputs`, `tabFlow`) printed into
`formal/activation.tla`, whose `Inv_TabShown`, `Inv_TabFiles`,
`Inv_TabFilesHosted`, `Inv_TabFilesListed`, `Inv_TabBound` and
`Inv_TabActive` TLC holds on `activation_tabs.cfg`; the tab schedules in
`test/activation_schedules_test.dart` are replayed against it.

#### Scenario: Switching to a parked tab

- **GIVEN** GitHub's active tab T1 with history and parked tab T2 with saved state
- **WHEN** the user picks T2 in the Tabs sheet
- **THEN** T1 becomes warm with its webview paused, not captured or disposed
- **AND** a webview is built for T2 with T2's bytes queued, and restores T2's back stack
- **AND** the number of live webviews grows by one

#### Scenario: Switching to a warm tab

- **GIVEN** GitHub's active tab T1 and warm tab T2, scrolled half way down an issue with a comment typed
- **WHEN** the user picks T2 in the Tabs sheet
- **THEN** T2's webview is shown as it was, scroll position and typed comment kept, and nothing reloads
- **AND** T1 becomes warm

#### Scenario: The tab left cannot stay warm

- **GIVEN** GitHub is on screen on T1, and the live webviews are at the loaded-site cap with no warm tab of another site to evict
- **WHEN** the user picks parked tab T2
- **THEN** T1 is captured under `gh.T1` and disposed before T2's webview is built
- **AND** the number of live webviews is unchanged

#### Scenario: A tab closed while its site activates

- **GIVEN** GitHub is not loaded, its active tab T1 has saved state and T2 is
  parked
- **WHEN** the user opens GitHub, and closes T1 in the Tabs sheet while the
  activation reads T1's state
- **THEN** GitHub's webview is built for T2 and shows T2's history
- **AND** T1's bytes are dropped, not restored into T2

#### Scenario: A reset lands a site at home while it activates

- **GIVEN** GitHub is not loaded, its active tab T2 has saved state and T1 is
  its home tab
- **WHEN** the user opens GitHub, and a reset lands it on T1 while the
  activation reads T2's state
- **THEN** GitHub's webview is built for T1 and shows T1's history
- **AND** T2's bytes are dropped, not restored into T1

#### Scenario: Leaving a site during a tab switch

- **GIVEN** GitHub is on screen on T1 and the user picks parked T2, whose saved state
  is being read
- **WHEN** the user goes back to the webspace list before that read returns
- **THEN** any capture of T1 is stored under T1, whose history it is, and never under T2

#### Scenario: A tab moved while its capture saves

- **GIVEN** GitHub is on screen on its link tab T2, which runs as GitHub
- **WHEN** the user goes back to the webspace list, and a reroute moves T2 to
  run as Mastodon while the capture going home makes is being saved
- **THEN** the file that save wrote under GitHub's key for T2 is removed
- **AND** moving T2 back to GitHub restores no back stack from before the move

#### Scenario: A tab closed while its capture saves

- **GIVEN** GitHub is on screen on T2, with T1 parked
- **WHEN** the user closes T2 and, before the close is done, taps Mastodon, so
  the capture leaving GitHub saves T2's history
- **THEN** once both settle no file holds T2's back stack, under any key
- **AND** GitHub's webview is built for T1

#### Scenario: Switching sites leaves tabs alone

- **GIVEN** GitHub is active on tab T2 and Mastodon's active tab is M1
- **WHEN** the user taps Mastodon in the strip
- **THEN** GitHub's active tab remains T2 and its webview is not disposed
- **AND** Mastodon's webview shows M1 exactly as it did

---

### Requirement: TAB-011 - Tab load state follows the site load policy

Whether a tab is loaded SHALL be decided by the site load policy (lazy
loading, the loaded-site cap, the memory-pressure cascade, retention
priorities) with the webview as its unit: a tab is loaded exactly when it has
a live webview, as the active tab of a loaded site or as a warm tab. The tab
list SHALL show that state on every row by strength alone, as a browser fades
an unloaded tab: a loaded tab at full strength, whether on screen, in the
background or warm, and every parked tab faded, since opening it reloads its
page. The tab on screen SHALL also carry the selected-row highlight. No text
label SHALL be drawn for the state; a screen reader SHALL be told it in words
instead. A switch to a parked tab SHALL put its new webview at the `resident`
tier; a switch to a warm tab SHALL keep its webview's tier.

#### Scenario: The policy unloads, the list shows it

- **GIVEN** Mastodon is loaded in the background and its active tab is drawn at full strength
- **WHEN** memory pressure disposes Mastodon's webview
- **THEN** the next time the tab list opens, Mastodon's active tab is faded
- **AND** no tab of any other site changes state

#### Scenario: A warm tab is drawn loaded

- **GIVEN** GitHub's tab T2 is warm
- **WHEN** the tab list opens
- **THEN** T2 is drawn at full strength, without the selected-row highlight

#### Scenario: A switch to a parked tab starts resident

- **GIVEN** GitHub is on screen at the `cacheCleared` tier
- **WHEN** the user switches to one of its parked tabs
- **THEN** the new webview is at the `resident` tier

---

## ADDED Requirements

### Requirement: TAB-023 - Warm tabs per running site

A running site SHALL keep at most `3 + min(hosted, 2)` warm tabs, where
`hosted` is the number of its warm tabs listed under other sites: at most 3
in its own tab list, at most 5 in all. A tab SHALL count toward the site it
runs as (LIR-018). When a tab going warm would exceed the limit, the site's
least recently used warm hosted tab SHALL be captured and disposed; an own
tab only when none of its warm tabs is hosted.

#### Scenario: A fourth own tab goes warm

- **GIVEN** GitHub has three warm tabs in its own list and none elsewhere
- **WHEN** the user switches from GitHub's active tab to a parked one
- **THEN** the tab left goes warm and GitHub's least recently used warm tab is captured and parked
- **AND** GitHub has three warm tabs

#### Scenario: Hosted tabs raise the limit

- **GIVEN** GitHub has three warm tabs in its own list and one warm tab listed under Mastodon
- **WHEN** a second GitHub tab listed under Mastodon goes warm
- **THEN** all five stay warm

#### Scenario: A hosted tab goes before an own one

- **GIVEN** GitHub has three warm own tabs and two warm tabs listed under Mastodon
- **WHEN** a third GitHub tab listed under Mastodon goes warm
- **THEN** the least recently used of the two earlier hosted tabs is captured and parked
- **AND** GitHub's three own warm tabs stay warm

---

### Requirement: TAB-024 - Warm tabs are evicted first

The loaded-site cap, the proactive cache clear and the memory-pressure
cascade SHALL take webviews in this order: warm hosted tabs listed under
sites other than the one on screen, then warm own tabs of those sites, then
warm tabs listed under the site on screen, hosted before own, then active
webviews by their retention priority. Within each, the least recently used
SHALL go first. The webview on screen and the activation target SHALL never
be taken.

#### Scenario: The cap takes a warm tab before a site

- **GIVEN** twenty live webviews: eighteen sites' active webviews and two warm tabs of Mastodon, which is not on screen
- **WHEN** the user opens a twenty-first site
- **THEN** Mastodon's least recently used warm tab is captured and disposed
- **AND** every site's active webview stays live

#### Scenario: The site on screen keeps its warm tabs longest

- **GIVEN** GitHub is on screen with a warm tab, and Mastodon in the background has a warm tab
- **WHEN** the cap must take one webview
- **THEN** Mastodon's warm tab goes, and GitHub's stays

---

### Requirement: TAB-025 - Only the active tab acts as the site

A warm tab's webview SHALL be paused. When a tab goes warm, any camera,
microphone or screen capture it holds SHALL end (MIC-014, SHARE-017). Only a
site's active tab SHALL play background audio (BGAUDIO-001) or post the
site's notifications (NOTIF-002); a warm tab's page SHALL NOT post
notifications.

#### Scenario: A share ends when its tab goes warm

- **GIVEN** a meeting site's active tab T1 shares the screen
- **WHEN** the user switches to the site's tab T2
- **THEN** the share ends and T1's webview is paused while warm

#### Scenario: A warm tab does not notify

- **GIVEN** a notification site with active tab T1 and warm tab T2, both on pages that post notifications
- **WHEN** the site's server sends a message
- **THEN** at most T1's page posts a notification

---

### Requirement: TAB-026 - A hosted tab stays warm as the site it runs as

A hosted tab SHALL be able to stay warm. It SHALL count toward the warm limit
of the site it runs as (TAB-023), and every rule that unloads by a site's
identity (a domain conflict, a proxy mismatch, a Tor exit mismatch) SHALL
judge it as that site. Its webview SHALL mount in its owner's slot, which
SHALL hold warm webviews while the owner's own webview is unloaded.

#### Scenario: A hosted tab outlives its owner's webview

- **GIVEN** Mastodon's list holds a warm tab running as GitHub
- **WHEN** the cap takes Mastodon's active webview
- **THEN** the GitHub tab stays warm in Mastodon's slot

#### Scenario: A proxy mismatch takes a warm hosted tab

- **GIVEN** Android without router mode, GitHub on proxy P2, and Mastodon's list holds a warm tab running as GitHub
- **WHEN** the user opens a site on proxy P1
- **THEN** the warm GitHub tab in Mastodon's list is captured and disposed with every other webview running on P2

---

### Requirement: TAB-027 - An unload of a site takes every webview running as it

An unload of a site for a domain conflict, a proxy mismatch or a Tor exit
mismatch SHALL take every live webview running as that site, active or warm,
in any site's tab list, under the container engine and under the legacy
shared jar alike. Under the legacy shared jar the site's cookies SHALL be
captured once for the unload, after its last webview goes, as before tabs
could be warm (ISO-002).

#### Scenario: A domain conflict takes the warm tabs too

- **GIVEN** the legacy shared jar, and `mail.example.com` loaded with an active and a warm tab
- **WHEN** the user opens `docs.example.com`
- **THEN** both of the mail site's webviews are disposed
- **AND** the mail site's cookies are captured once

---

### Requirement: TAB-028 - A warm tab's history survives as a parked tab's does

A warm tab's navigation state SHALL be captured to `<siteId>.<tabId>`, when
`persistsNavState` is true, wherever the active tab's is (PAUSE-009: going
home, the app going to the background), and before its webview is disposed,
so a process the OS ends while tabs are warm loses no tab's back stack.

#### Scenario: The app is killed with warm tabs

- **GIVEN** GitHub has a warm tab T2 several pages deep
- **WHEN** the app goes to the background and the OS ends its process
- **THEN** on the next launch, opening T2 restores its back stack from `gh.T2`
