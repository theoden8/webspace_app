# Site unread badges

## ADDED Requirements

### Requirement: UNREAD-001 - A page's own unread count is read from its title

`unreadCountFromTitle` SHALL read a count from the two placements chat and
mail sites use in a browser tab title: a leading `(N)` (`(3) Messenger`), and
a `(N)` closing the title's first segment, where segments are separated by a
spaced dash, en or em dash, bar, middle dot or bullet
(`Inbox (3) - user@example.com - Mail`). `N+` SHALL read as `N`, and digits
grouped by `,`, `.` or a no-break space SHALL read as one number. A
parenthesised number anywhere else SHALL be read as part of the page's name,
not a count. `(0)` is a count of zero.

Implementation: `lib/services/site_unread_service.dart`.

#### Scenario: Leading count

**Given** a site's page title is `(3) Messenger`
**When** the title is read
**Then** the count is 3

#### Scenario: Count closing the first segment

**Given** a site's page title is `Inbox (1,234) - user@example.com - Mail`
**When** the title is read
**Then** the count is 1234

#### Scenario: A number in the page name

**Given** a site's page title is `Apollo 11 (1969 film) - Wikipedia` or `News - Site (2)`
**When** the title is read
**Then** no count is read

---

### Requirement: UNREAD-002 - The page count follows the live page

The site's own webview SHALL report every main-frame title change
(`onTitleChanged`), including changes a page makes without navigating. A title
that states a count SHALL set the site's page count at once. A title that
states none SHALL clear it only once it has held for 5 seconds, and a later
countless title SHALL NOT extend that wait, so a page alternating its title
between the count and a message line does not blink the badge. When the site's
webview is disposed the page count SHALL be cleared, since the page that stated
it is gone. Opening the site SHALL NOT clear the page count: it follows the
page, which clears it when the user reads the messages. A nested webview
(`InAppWebViewScreen`) SHALL NOT report its title, because its page is not the
site's.

#### Scenario: A read count clears

**Given** a site's title is `(2) Chat`
**When** the user reads the messages and the title becomes `Chat`
**Then** the badge is gone 5 seconds later

#### Scenario: An attention-seeking title does not blink

**Given** a site's title is `(1) Chat`
**When** the page alternates it with `Alice sent a message` every second
**Then** the badge stays at 1 and is not redrawn

#### Scenario: An unloaded site states nothing

**Given** a site's title is `(2) Chat`
**When** its webview is disposed (unload, memory pressure)
**Then** its page count is 0

---

### Requirement: UNREAD-003 - Notifications the user missed are counted until seen

A post that reaches the `webNotification` handler SHALL be counted for the
site after the NOTIF-010 frame check, so a cross-origin frame cannot badge the
site, and whether or not the OS lets the notification show. A post SHALL NOT be
counted while the site is on screen: it is the current site and the app is in
the `resumed` lifecycle state. A post carrying a tag SHALL replace the site's
earlier post with that tag, as the OS notification does (NOTIF-009). The count
SHALL clear when the site becomes the current site, and when the app returns to
the foreground with the site current.

#### Scenario: A post from a site in the background

**Given** site "Chat" has notifications enabled and site "News" is on screen
**When** "Chat" posts `new Notification("Alice")` twice
**Then** "Chat" has 2 missed notifications

#### Scenario: A tagged post replaces

**Given** site "Mail" posted `new Notification("2 unread", {tag: "inbox"})` while off screen
**When** it posts `new Notification("3 unread", {tag: "inbox"})`
**Then** "Mail" has 1 missed notification

#### Scenario: Looking at the site clears them

**Given** "Chat" has 2 missed notifications
**When** the user switches to "Chat"
**Then** "Chat" has none

---

### Requirement: UNREAD-004 - Where the badge shows

A site's badge SHALL show its page count when the page states one, otherwise its
missed notifications, and nothing when both are 0. It SHALL be drawn as a count
pill capped at `99+`:

- on the favicon of both drawer tile layouts, at the favicon's top-start corner,
  in the shared tile builder (`_buildSiteGridTileContent`) so reorderable and
  static tiles match. Top-start rather than top-end because the reorderable
  tile's overflow button covers the top-end corner of a narrow tile;
- after the site's name on its tab-strip tab, taking no room when there is
  nothing to show.

The app bar's menu button SHALL carry a dot while any site the drawer lists,
other than the one on screen, has a badge. Badges SHALL rebuild on their own
when a count moves. The pill's semantic label SHALL be
`siteSettingsNotifications` + ": " + the count, composed from the existing
settings string (PERMBADGE-003), and the dot's SHALL be
`siteSettingsNotifications`.

#### Scenario: The page count wins

**Given** "Chat" has 1 missed notification
**When** its title becomes `(7) Chat`
**Then** its badge reads 7

#### Scenario: The menu button tells of an unseen site

**Given** "News" is on screen and "Chat" in the same webspace has a badge
**When** the drawer is closed
**Then** the menu button carries a dot

---

### Requirement: UNREAD-005 - Unread state lives in memory only

Unread state SHALL NOT be written to disk, preferences, secure storage, logs or
OS notification state; a cold start begins with none. A site's state SHALL be
forgotten when the site is deleted, when a settings import leaves it out, and
when the archive that holds it closes, so nothing held for an archive-tier
site outlives the archive (ARCH-001, ARCH-006).

#### Scenario: Closing an archive

**Given** an archive-tier site's title is `(2) Chat`
**When** its archive is closed
**Then** nothing is held for its `siteId`
