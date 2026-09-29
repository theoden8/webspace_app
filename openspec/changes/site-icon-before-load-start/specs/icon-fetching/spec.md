## ADDED Requirements

### Requirement: ICON-016 - Callbacks That Overtake the Load Start

An icon, or a load report from the watcher, that reaches the app before its
document's `onLoadStart` SHALL still count for that document. ICON-009 relies
on `onLoadStart` arriving first, and on the first page of a cold Android
WebView it does not: `onPageStarted` is posted to the looper, while
`onReceivedIcon` is called from native code and can overtake it.

- **An icon with no web document known.** `SiteIconEngine` SHALL hold an icon
  that arrives before any document is known, or while the known document is
  not http(s), and SHALL judge it against the next http(s) document it learns
  of, by `onLoadStart` or `onLoadStop`, as a mid-load icon of that document
  (ICON-009): taken when that document is the site's and so is the one it
  replaced. Held icons are judged once and never carried past that document.
  At most 16 are held.
- **A late start of a document that reported its load.** Where the app fetches
  the declared links (ICON-013), a start for the URL whose load report already
  arrived, before that load's `onLoadStop`, SHALL be that document's own
  start and not a new document: a fetch it claimed stays its own, and links it
  reports afterwards can still be claimed. After `onLoadStop`, a start for the
  same URL is a new document, as before.
- **Visible order.** The engine's decisions SHALL go to the app log under
  `SiteIcon`, with no URL, so the order a device saw can be read back.

#### Scenario: The first page's early icon is kept

**Given** a site's webview is the first in a fresh launch
**And** its page declares 32px and 192px icons, and the 32px one lands first
**When** the webview reports the 32px icon before `onLoadStart`
**Then** the site takes the 32px icon once the start arrives
**And** takes the 192px icon when it lands

#### Scenario: An early icon of another host's page is not kept

**Given** a site whose home is `https://example.com/`
**When** its webview reports an icon before the start of
`https://other.test/`
**Then** the site's icon does not change, then or when a page of
`example.com` loads later

#### Scenario: The declared links survive a late start

**Given** Site icons only is on and a site's page reports its load and its
icon links before its `onLoadStart`
**When** the start arrives, before `onLoadStop`
**Then** the links are claimed once and the fetched icon becomes the site's
