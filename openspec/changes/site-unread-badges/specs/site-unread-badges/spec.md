# Site unread badges

## ADDED Requirements

### Requirement: UNREAD-001 - Web notifications the user missed are counted until seen

A site's unread count SHALL be the number of web notifications it posted
through the polyfill (`new Notification`, page-context
`registration.showNotification`) while it was not on screen, and nothing else.
A post that reaches the `webNotification` handler SHALL be counted after the
NOTIF-010 frame check, so a cross-origin frame cannot badge the site, and
whether or not the OS lets the notification show. A post SHALL NOT be counted
while the site is on screen: it is the current site and the app is in the
`resumed` lifecycle state. A post carrying a tag SHALL replace the site's
earlier post with that tag, as the OS notification does (NOTIF-009). The count
SHALL clear when the site becomes the current site, and when the app returns to
the foreground with the site current.

Only a site with `effectiveNotificationsEnabled` can post, so only such a site
can carry a count.

Implementation: `lib/services/site_unread_service.dart`.

#### Scenario: A post from a site in the background

**Given** site "Chat" has notifications enabled and site "News" is on screen
**When** "Chat" posts `new Notification("Alice")` twice
**Then** "Chat" has a count of 2

#### Scenario: A tagged post replaces

**Given** site "Mail" posted `new Notification("2 unread", {tag: "inbox"})` while off screen
**When** it posts `new Notification("3 unread", {tag: "inbox"})`
**Then** "Mail" has a count of 1

#### Scenario: Looking at the site clears it

**Given** "Chat" has a count of 2
**When** the user switches to "Chat", or taps one of its OS notifications
**Then** "Chat" has a count of 0

#### Scenario: A page title is not a count

**Given** a site's page title is `(3) Chat` and it has posted no notification
**When** its drawer tile renders
**Then** no badge is drawn

---

### Requirement: UNREAD-002 - Where the badge shows

A site with a count SHALL show it as a pill capped at `99+`:

- on the favicon of both drawer tile layouts, at the favicon's top-start corner,
  in the shared tile builder (`_buildSiteGridTileContent`) so reorderable and
  static tiles match. Top-start rather than top-end because the reorderable
  tile's overflow button covers the top-end corner of a narrow tile;
- after the site's name on its tab-strip tab, taking no room when there is
  nothing to show.

The app bar's menu button SHALL carry a dot while any site the drawer lists has
a count. Badges SHALL rebuild on their own when a count moves. The pill's
semantic label SHALL be `siteSettingsNotifications` + ": " + the count,
composed from the existing settings string (PERMBADGE-003), and the dot's SHALL
be `siteSettingsNotifications`.

#### Scenario: The menu button tells of an unseen site

**Given** "News" is on screen and "Chat" in the same webspace has a count
**When** the drawer is closed
**Then** the menu button carries a dot

---

### Requirement: UNREAD-003 - Unread state lives in memory only

Unread state SHALL NOT be written to disk, preferences, secure storage, logs or
OS notification state; a cold start begins with none. A site's state SHALL be
forgotten when the site is deleted, when a settings import leaves it out, and
when the archive that holds it closes, so nothing held for an archive-tier
site outlives the archive (ARCH-001, ARCH-006).

#### Scenario: Deleting a site

**Given** "Chat" has a count of 2
**When** the user deletes "Chat"
**Then** nothing is held for its `siteId`
