# External Scheme Handling — magnet delta

## ADDED Requirements

### Requirement: EXT-010 - A magnet link is named by what it carries

When the external-scheme prompt (EXT-004) is for a `magnet:` URI, it SHALL
show the display name (`dn`) when the URI carries one, and the content hash
(`xt` as `urn:btih:` or `urn:btmh:`) shortened to its first and last six
characters, in place of the raw URI, which a page can fill with trackers and
parameters to bury what is being opened. A URI with no `xt` SHALL be shown as
not a valid magnet link and offer no launch. The prompt SHALL offer Cancel
and Open in app; there is no web fallback to open in the browser (EXT-005).

The parsing is a pure function, and the prompt's strings go through the
app's localizations.

#### Scenario: A magnet with a name

**Given** a page links
`magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056&dn=debian-13.iso&tr=udp://tracker.example:1337`
**When** the user taps it
**Then** the prompt names `debian-13.iso` and `c9e157…d53056`
**And** offers Cancel and Open in app

#### Scenario: No content hash

**Given** a page links `magnet:?dn=something`
**When** the user taps it
**Then** the prompt says the link is not a valid magnet link
**And** offers no way to launch it

---

### Requirement: EXT-011 - An external-scheme URL is not a site

A URL whose scheme the webview cannot render and the app does not serve
itself (`magnet:`, `tel:`, `mailto:`, `intent:`, a custom app scheme) SHALL NOT
become a site URL: Add Site, site editing, a QR code and a backup import SHALL
refuse it, saying it opens in another app. Entered in the URL bar, it SHALL go
to the external-scheme prompt as a tap on such a link does, not load as a
navigation.

#### Scenario: Paste a magnet into Add Site

**Given** the user is on Add Site
**When** they paste a `magnet:` URI
**Then** no site is created
**And** the screen says magnet links open in another app

#### Scenario: Enter a magnet in the URL bar

**Given** a site is on screen
**When** the user submits a `magnet:` URI in its URL bar
**Then** the external-scheme prompt opens for it
**And** the site's webview does not navigate

---

### Requirement: EXT-012 - The app never fetches what a magnet names

The app SHALL NOT request any URL a `magnet:` URI carries (`tr` trackers,
`ws` web seeds, `xs` and `as` sources), on any route: only the app the user
chooses is handed the URI. A web seed is offered to nobody as a link.

#### Scenario: A magnet with a web seed

**Given** a magnet carries `ws=https://mirror.example/debian-13.iso`
**When** the prompt is shown and the user cancels
**Then** no request was made to `mirror.example` or to any tracker
