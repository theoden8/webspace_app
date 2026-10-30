# Icon Fetching Specification

## Purpose

Icon fetching for the Webspace app: a site's icon comes only from the site
itself, from the links its pages declare and from its home page's markup,
and no third-party icon service is ever asked (ICON-014).

A user-set custom icon (`WebViewModel.customIconPng`, see EDIT-008 in
[site-editing](../site-editing/spec.md)) takes precedence over every fetched
source: when present, `UnifiedFaviconImage` renders it directly and skips
fetching entirely.

## Status

- **Date**: 2026-01-25
- **Status**: Completed

---

## Requirements

### Requirement: ICON-002 - Icon Sources

The system SHALL find a site's icon in what the site's home page serves, read
through the site's proxy:

1. HTML parsing: the `rel=icon` and `rel="shortcut icon"` links of the home
   page, after its redirects (at most 5), resolved against the document they
   landed on
2. `/favicon.ico` on the site's host, and on the first other host a redirect
   sends the home page to: `gmail.com` answers with a 301 to
   `mail.google.com`, whose favicon is Gmail's, then redirects on to a
   sign-in page on a third host, whose favicon is not and is never asked for

and SHALL pick the best of them by ICON-003's score. The page icon the site's
own webview produces once the site is open (ICON-009, ICON-013) wins over
this when present.

Every request SHALL name the user agent the site's webview sends when the user
set none (`HostBrowser.sentUserAgent`, UAID-005), so a site that walls other
clients answers as it answers the site: `linkedin.com` sends Dart's own user
agent a CAPTCHA page with no icon in place of its 301 to `www.linkedin.com`.
Linux WPE does not say its user agent, so there the request goes out under
Dart's.

#### Scenario: Select best available icon

**Given** the home page declares a 32px and a 64px PNG icon
**And** the site's host serves `/favicon.ico`
**When** selection is made
**Then** the 64px icon is chosen

#### Scenario: Fall back to /favicon.ico

**Given** the home page declares no icon
**And** the site's host serves `/favicon.ico`
**When** selection is made
**Then** `/favicon.ico` is chosen

#### Scenario: A site that walls other clients

**Given** `https://linkedin.com/` answers a client that does not name a
browser with a CAPTCHA page, and a browser with a 301 to
`https://www.linkedin.com/`
**When** the icon is fetched
**Then** the request names the webview's user agent
**And** the icon is found on `www.linkedin.com`

#### Scenario: A home page that redirects to another host

**Given** `https://gmail.com/` redirects to `https://mail.google.com/mail/u/0/`
**And** that redirects to a sign-in page on `accounts.google.com`, which
declares no icon
**When** the icon is fetched
**Then** `https://mail.google.com/favicon.ico` is chosen
**And** `accounts.google.com/favicon.ico` is not requested

---

### Requirement: ICON-003 - Quality Scoring System

Icons SHALL be scored based on quality:

| Score | Type |
|-------|------|
| 1000 | Colored SVG icons (scale-invariant) |
| width | Raster icons of known width (`/favicon.ico` counts as 16) |
| 50 | Raster icons of unknown width |
| 30 | Monochrome SVG icons |

#### Scenario: Prioritize colored SVG

**Given** a site has both a PNG favicon and a colored SVG logo
**When** icons are fetched
**Then** the colored SVG is selected (score 1000 > PNG scores)

---

### Requirement: ICON-004 - SVG Color Detection

The system SHALL detect whether SVG icons are colored or monochrome.

#### Scenario: Detect colored SVG

**Given** an SVG contains `fill="#2185d0"`
**When** color detection runs
**Then** the SVG is marked as colored (quality 1000)

#### Scenario: Detect monochrome SVG

**Given** an SVG contains only `fill="#000"` and `fill="#fff"`
**When** color detection runs
**Then** the SVG is marked as monochrome (quality 30)

#### Scenario: Reject CSS visibility-switching SVG

**Given** an SVG contains a `<style>` block with `display: none` (e.g. theme-aware
icons that toggle between `#light-icon` and `#dark-icon` groups via CSS or
`@media (prefers-color-scheme: dark)`)
**When** color detection runs
**Then** the SVG is treated as low quality (not colored)
**And** a bitmap icon is preferred instead

This guards against flutter_svg's limited CSS support: `display: none` from
`<style>` blocks is not honored, so every `<g>` group renders and hidden
background rects can obscure the visible icon. duck.ai's favicon.svg is a
concrete example — without this guard, the icon appears as a near-empty
white rounded square.

---

### Requirement: ICON-005 - SVG Dark Mode Support

SVG icons with CSS media queries SHALL render correctly based on app theme
when flutter_svg supports the CSS features used.

#### Scenario: Render SVG in dark mode

**Given** an SVG contains `@media (prefers-color-scheme: dark)`
**And** the app is in dark mode
**When** the SVG is rendered
**Then** the dark mode styles are applied

#### Scenario: Reject SVGs relying on CSS visibility toggles

**Given** an SVG uses `<style>` with `display: none` to hide the inactive
theme variant (rather than conditional styling of a single rendered tree)
**When** icon selection runs
**Then** the SVG is rejected by ICON-004's color detection
**And** a bitmap icon from the same site is selected instead

This avoids rendering all theme variants simultaneously, which flutter_svg
would otherwise do.

---

### Requirement: ICON-008 - Icon Caching

Fetched icons SHALL be cached to avoid redundant network requests. Within a
session, what the app holds of a site's icon SHALL NOT be asked for again:

- **An icon drawn again** (an open folder draws its tiles again on every page
  and every layout) SHALL show the held image or SVG, or the globe of a site
  known to have none, from its first frame and without a request.
- **A site that answered with its page and named no icon** SHALL NOT be
  searched again until its icon is refreshed (the edit dialog's refresh, a
  TLS pin, Reset icon cache).
- **A site that was not reached** (the network failed, its page came back
  with an error, its proxy was not up) SHALL be searched again, so ICON-017
  can make good what it missed.

#### Scenario: An icon drawn again shows at once

**Given** a site's icon was drawn this session
**When** it is drawn again, as a folder's page is swiped back to
**Then** its first frame shows the icon, not a spinner
**And** no request is made

#### Scenario: A site with no icon is not searched again

**Given** a site's home page loaded and named no icon, and it has no
`/favicon.ico`
**When** its icon is drawn again this session
**Then** the globe shows at once and no request is made

#### Scenario: A site not reached is searched again

**Given** a site's icon search failed because the device was offline
**When** its icon is drawn again once online
**Then** the site is searched again and its icon found

#### Scenario: Return cached icon

**Given** an icon was fetched for example.com 5 minutes ago
**When** the icon is requested again
**Then** the cached result is returned immediately

#### Scenario: Page refresh does not invalidate icon cache

**Given** a site has a cached favicon
**When** the user refreshes the page from the nav bar
**Then** only the page is reloaded
**And** the cached favicon is NOT re-fetched

#### Scenario: The edit dialog's refresh invalidates icon cache

**Given** a site has a cached favicon
**When** the user taps "Refresh Title & Icon" in the site's edit dialog
**Then** the favicon cache is invalidated and the icon is re-fetched
**And** the page title is also refreshed, into the name field

---

### Requirement: ICON-009 - Page Icon From the Site's Own Webview

On Android, and on Linux from WPE 2.54, the icon the site's own root webview
reports SHALL be preferred over every fetched candidate (ICON-002) while it
is present, and no fetch SHALL run for the site while it is present. It is
fetched by the webview itself, so it goes through the site's container and
proxy and names no third party. Android reports it through
`WebChromeClient.onReceivedIcon`; WPE announces each finished set of a
page's icons as `notify::page-icons`, which the fork forwards one PNG at a
time as the same `onReceivedIcon`. The rules below were written for
Android's callback and apply to both.

The callback carries a bitmap and nothing else: no URL, no document. Chromium's
WebView downloads every `rel=icon` candidate, so it fires once per candidate in
download-completion order, again whenever the page edits its icon links, and
for whatever document is loaded. `SiteIconEngine` therefore takes an icon only
when all of these hold:

- while a main-frame load is in flight, both documents the icon can belong
  to are the site's: the loading document and the one it replaced are each on
  the site's host and neither has edited its icon links (a document that is
  not http(s) announces no icons, so the one before it counts instead);
- the loaded document is http(s) and on the site's host, with a leading `www.`
  folded (sharing the registrable domain is not enough: a login bounce to
  `accounts.example.com` shows that host's icon, not the site's);
- the page has not edited its icon links since load (ICON-011);
- it is at least the ICON-010 floor and larger than any icon this document
  already produced.

A mid-load icon cannot be told apart by timing. The replaced document may
still have downloads out, and the loading document announces its icons after
its load event, which WebView can report after the icon: `onReceivedIcon` is
called from native code, while `onPageFinished` is posted from
`didStopLoading`. `onLoadStart` is posted at commit with the committed URL (for
every navigation of an app other than GMS), so the loading document's host is
known by then. A first page, or a page after a page of the site, therefore
keeps its own icon wherever it lands; a page after another host's page or after
a badge swap waits for `onLoadStop`.

Chromium downloads icons only while a process-wide flag is set, and the one
public way to set it is `WebIconDatabase.getInstance().open(path)`
(`SiteIconPlugin.kt`); the path is ignored. The app calls it right before it
builds the first site webview, since `getInstance` starts Chromium.

Only the site's root webview reports: a nested `InAppWebViewScreen` or a popup
shows another page, usually on another host.

The icon is kept by `SiteIconStore`, keyed by the site's home URL. It is
written to disk only when the site is not incognito (archive tier counts as
incognito, see [archive](../archive/spec.md) ARCH-006); otherwise it lives for
the session. An entry loaded from disk yields to the first icon of a launch
that is at least as large, so an icon the site has since dropped heals on the
next launch; within a launch only a larger icon replaces it, so pages of one
site with different icons do not flip it. `FaviconUrlCache.invalidate` (the
edit dialog's refresh, archive close and move) removes it, and the startup,
post-import and post-delete sweeps drop files for sites no longer kept on disk.

WKWebView has no public API for a page's icon, and the SPI that has one
(`_WKIconLoadingDelegate`) cannot ship through the App Store (guideline
2.5.1), so iOS and macOS fetch the declared links instead (ICON-013). WPE
WebKit had no favicon API before 2.54 (the `favicon` property is WebKitGTK's),
so an older WPE fetches them too. From 2.54 a view that wires `onReceivedIcon`
has the fork turn favicons on for its network session; WebKit then keeps the
icons in `icondatabase/WebpageIcons.db` under the container's cache
directory, which `deleteContainer` removes, and an incognito or archive-tier
site's ephemeral session keeps them in memory. The app reads the WPE version
at startup (`WpePageIcons`): a plugin built against 2.54 needs it at run
time, while one built against an older WPE forwards nothing even on a newer
one, and its sites keep the ICON-002 icon.

#### Scenario: Largest icon of the page wins

**Given** a site page declares 16px, 32px and 192px icons
**And** they finish downloading in the order 32, 192, 16
**When** the webview reports each of them
**Then** the site's icon is the 192px one
**And** the 16px icon is never taken

#### Scenario: An icon that lands before onLoadStop is taken

**Given** a site page whose only icon is 48px
**And** it is the webview's first page, or the page before it was on the
site's host and kept its icon links
**When** the webview reports the icon before `onLoadStop`
**Then** the site's icon is the 48px one

#### Scenario: A mid-load icon after another host's page is not taken

**Given** a site whose home is `https://mail.example.com/`
**And** its webview showed `https://accounts.example.com/login`
**When** it starts loading `https://mail.example.com/` and reports an icon
before `onLoadStop`
**Then** the site's icon does not change

#### Scenario: Another host's icon is not the site's

**Given** a site whose home is `https://mail.example.com/`
**When** the webview lands on `https://accounts.example.com/login` and reports
its icon
**Then** the site's icon does not change

#### Scenario: Preferred over fetched candidates

**Given** the site's webview has reported a 64px icon
**And** the home page's markup declares a 256px one
**When** the drawer renders the site
**Then** it shows the webview's icon
**And** no request goes out for the home page's icon

#### Scenario: Incognito icon does not reach disk

**Given** an incognito or archive-tier site
**When** its webview reports an icon
**Then** the drawer shows it for the session
**And** nothing is written under the app's `site_icons` directory

---

### Requirement: ICON-010 - Page Icon Preference Floor

An icon from the webview SHALL be taken only when both edges are at least
32px. Below that, the site keeps the ICON-002 icon: an upscaled 16px
`favicon.ico` frame reads poorly in the drawer.

#### Scenario: 16px page icon does not displace fetched icons

**Given** a site whose only page icon is a 16px `favicon.ico`
**When** the webview reports it
**Then** the site keeps the ICON-002 icon

---

### Requirement: ICON-011 - Icons Swapped In After Load Are Not the Site's

When the top document edits the `rel=icon` links that are direct children of
`<head>` (the only ones Blink reads) after the set it announced at load, the
engine SHALL take no further icon for that document. Those later rounds are
how pages draw unread counts and status dots into their favicon. A page that
declared no icon at load and adds its first one later (an SPA mounting its
`<head>`) has not changed an announced set, and its icon counts.

The icon-link watcher (`icon_link_watcher_shim.dart`) is injected at document
start into the main frame only and reports through the frame-aware
`wsIconLinksChanged` handler, which ignores subframes. Its timing is pinned
against Chrome's own favicon requests by
`test/browser/icon_link_watcher_real.test.js`, and what Android WebView then
delivers by `integration_test/site_icon_test.dart`.

A page that already shows a badge when its load finishes cannot be told apart
from its real icon: the callback carries no URL. ICON-009's launch rule heals
it on a later launch without the badge.

#### Scenario: Unread badge after load is ignored

**Given** a site page whose icon is `a.png`
**And** a script swaps it for a larger `badge.png` after load
**When** the webview reports both
**Then** the site's icon stays `a.png`

#### Scenario: SPA icon added after load counts

**Given** a page that declares no icon at load
**When** its script adds `<link rel="icon" href="/app.png">` to `<head>`
**Then** the icon for `/app.png` can become the site's icon

---

### Requirement: ICON-013 - Page Icon From the Links the Page Declares

On iOS, macOS and Linux before WPE 2.54, where the webview reports no icon,
the app SHALL fetch the icon links the top
document declared at load, and SHALL apply ICON-009's host, size and store
rules and ICON-010's floor to them. `pageIconSource` decides which of the two
a site's webview uses when the webview is created.

It overlaps ICON-002, which already reads the home page's HTML through the
site's proxy. What it adds: the links of the page actually shown, where a
cookie-less fetch of the home URL meets a bot wall, a sign-in redirect or a
script-set icon (6 of the 17 suggested sites that loaded in a 2026-09 probe).
Most sites declare only small icons (a `favicon.ico`, 32 to 48px), so a
site's icon is often that size. It ran as the Page icons experiment first; on
device it found the icon a site's pages declare once each page had loaded.

- **What is fetched.** The watcher reports the document's load event through
  the frame-aware `wsIconDocumentLoaded` handler, and right after it, through
  `wsIconLinks`, the links Blink and WebKit take:
  `rel=icon` links that are direct children of `<head>` (WebKit's
  `LinkIconCollector` reads the same scope), `media` applied, `href`
  resolved. With none, the document's icon is `/favicon.ico`.
  `siteIconCandidates` keeps http(s) links and `data:image/` links up to 256
  KiB, skips SVG (the ICON-002 path renders SVG with its colour checks) and
  links whose declared `sizes` are all under the floor, upgrades an `http:`
  link on an `https:` document to `https:`, puts declared sizes first,
  largest first, and keeps at most 6.
- **When.** `SiteIconEngine.claimIconLinks` allows one fetch per document, and
  only when the document at the bridge's `requestUrl` is on the site's host
  and not mid-load. A result that arrives after its document was replaced is
  dropped. Links the page edits after load are never fetched (ICON-011); the
  set it declared at load stays the site's icon even after the page badges
  it.
- **How.** Every request goes through the site's proxy and fails closed like
  every other Dart-side fetch (LEAK-003). The page chooses the URL, so each
  hop, the link and every redirect, must pass the site's DNS blocklist level
  and content-blocker rules as an `image` request from the document, and the
  private-range guard the user-script bridge uses (US-DR-007). The page's own
  host is exempt from the range guard, so a site the user added on their LAN
  gets its icon. A redirect may not drop from https to http; at most 3
  redirects and 1 MiB are read.
- **Decoding.** Flutter's codecs (PNG, ICO, JPEG, GIF, WebP, BMP). An image
  over 1024px on an edge is not decoded; the largest usable one is scaled to
  at most 192px, the limit Android WebView applies, and offered as PNG once
  per document. Decoded results are cached per webview (24 entries) so the
  pages of one site do not refetch the same icon; a failed request is tried
  again by the next document.

The request carries none of the site's cookies, so an icon served only to a
signed-in user is not fetched. Fetching through
`WKWebView.startDownload(using:)`, which uses the site's own data store, would
close that and needs a fork change.

#### Scenario: Largest declared icon, and nothing under the floor fetched

**Given** a site page on macOS declares 16px, 32px and 192px icons with
`sizes`
**When** the page loads
**Then** the site's icon is the 192px one
**And** the app never requests the 16px link

#### Scenario: A blocked icon host is not contacted

**Given** a site whose DNS blocklist blocks `tracker.test`
**And** its page declares `https://tracker.test/icon.png`
**When** the page loads
**Then** no request goes to `tracker.test`

#### Scenario: A public page cannot point the app at the LAN

**Given** a site on `https://example.com/`
**And** its page declares `http://192.168.1.1/icon.png`, or a link that
redirects there
**When** the page loads
**Then** no request goes to `192.168.1.1`

#### Scenario: No icon links

**Given** a site page that declares no icon
**When** the page loads
**Then** the app fetches the document's `/favicon.ico`
**And** takes it when it is at least 32px

#### Scenario: A badge after load starts no fetch

**Given** a site page whose icon is `a.png`
**When** a script swaps it for `badge.png` after load
**Then** the site's icon stays `a.png`
**And** `badge.png` is never requested by the app

---

### Requirement: ICON-014 - Site Icons Only

A site's icon SHALL come only from the site itself:

- **No third-party service.** No path that fetches an icon (the drawer, the
  add-site preview, the home shortcut export) SHALL ask a third-party icon
  service. What there is: ICON-013's declared links and ICON-002's page
  scrape and `/favicon.ico`, which go to the hosts the site names, through its
  proxy.
- **Nothing resolved earlier.** Releases up to v0.3.5 asked third-party
  icon services and kept the URL they resolved in `FaviconUrlCache` on disk,
  under `favicon_url_`. The cache now keeps its URLs under `favicon_src_`,
  and `FaviconUrlCache.initialize` SHALL drop every `favicon_url_` entry at
  startup, so each icon is found again on its site and no URL an earlier
  release resolved is ever rendered. The app holds no list of services to
  recognise them by.
- **A webview that reports its icon keeps it.** On Android, and on Linux
  from WPE 2.54, the site's icon is the one the webview itself downloads and
  reports through `onReceivedIcon` (ICON-009), through the site's container
  and proxy. The app SHALL NOT also fetch the declared links there: the load
  report (`wsIconDocumentLoaded`) SHALL never run beside `onReceivedIcon`,
  since on Android it reaches Dart through a posted Java message that the
  callback can overtake. The link report rides the same bridge after the load
  report, in order, so the two cannot swap.

It shipped first as the Site icons only experiment ([developer-tools](../developer-tools/spec.md)
DEVTOOLS-011), off by default, which also sent Android to the declared links
in place of its webview's icon. The third-party half graduated and the Android
half did not; the switch and its pref (`experimentalSiteIconsOnly`, written
by v0.3.3 to v0.3.5) went with it. A site that declares only small icons
shows a smaller one, or the scrape's, or the placeholder.

#### Scenario: No request to a third party

**Given** a fresh install
**When** the icon of `https://example.com/` is fetched
**Then** every request goes to `example.com`
**And** none goes to a host the site does not name

#### Scenario: An icon URL an earlier release kept is dropped

**Given** a site whose icon URL an earlier release kept under `favicon_url_`
**When** the app starts after the upgrade
**Then** that entry is gone, and no other pref changes
**And** the icon is fetched again from the site

#### Scenario: Android takes its webview's icon

**Given** an Android build
**And** a site page that declares 16px, 32px and 192px icons with `sizes`
**When** the site loads that page
**Then** the site's icon is the 192px one, as WebView reports it
**And** the app fetches none of the declared links itself

#### Scenario: The old switch is not read

**Given** a device that stored `experimentalSiteIconsOnly` off
**When** the icon of `https://example.com/` is fetched
**Then** every request goes to `example.com`

---

### Requirement: ICON-015 - Reset Icon Cache

While developer mode is on, App settings SHALL offer **Reset icon cache**,
with its explanation behind a `HintButton`. It SHALL drop every icon the app
keeps: the resolved URLs and SVGs in `FaviconUrlCache`, the icons sites
reported in `SiteIconStore` (memory and disk), and the icon service's memory.
Every icon on screen is then fetched again (`reloadAllIcons`), and a site's
own icon returns once the site loads again.

#### Scenario: Every cached icon goes, nothing else does

**Given** developer mode is on, a resolved icon URL and SVG are cached, and a
site has a reported icon on disk
**When** the user taps Reset icon cache
**Then** no `favicon_` pref and no stored site icon remains
**And** no other pref changes
**And** a confirmation says the icon cache was cleared

---

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

**Given** a site's page reports its load and its icon links before its
`onLoadStart`
**When** the start arrives, before `onLoadStop`
**Then** the links are claimed once and the fetched icon becomes the site's

---

### Requirement: ICON-017 - One Icon Wherever the Site Shows

A site's fetched icon SHALL be the same wherever the site shows. A folder's
preview on the library home is drawn at launch and stays mounted, while the
folder's own tiles are drawn afresh each time it opens, so any step that came
back with nothing at launch (offline, a proxy or Tor not yet up, a timeout)
SHALL be made good, without the preview being drawn afresh, when another
widget's same step later succeeds:

- **The search.** An icon whose site's search found nothing SHALL take the icon
  a later search for the same site finds.
- **The image.** An icon whose URL is known (found earlier, or kept from a
  past launch) but whose image or SVG body failed to come SHALL take it once a
  later fetch of that URL brings it.

A search or fetch that ends with nothing SHALL NOT replace what another
brought while it ran.

#### Scenario: A preview drawn offline takes the icon found later

**Given** a site's icon is drawn in a folder's preview while the device is
offline, and shows the globe
**When** the folder is opened online and the site's tile finds its icon
**Then** the preview shows that icon too

#### Scenario: A preview whose image did not come at launch takes it later

**Given** a site's icon URL is kept from a past launch
**And** its folder's preview was drawn before the network was up, so its
image (or SVG) did not come and the preview shows the globe
**When** the folder is opened online and the site's tile fetches the image
**Then** the preview shows the image too

#### Scenario: A stalled search keeps the found icon

**Given** two searches for one site's icon run at once
**When** one finds the icon and the other then ends with nothing
**Then** both answer with the found icon, and a later request is answered from
the cache
**And** two fetches of one icon's image or SVG behave the same way

## Files

### Created
- `lib/services/icon_service.dart` - Icon fetching service
- `lib/services/site_icon_engine.dart` - Which page icon is the site's, and which declared links to fetch (ICON-009/010/013)
- `lib/services/site_icon_store.dart` - Memory + disk store for it
- `lib/services/icon_link_watcher_shim.dart` - Reports icon-link edits after load (ICON-011), and the load event and announced links (ICON-013)
- `lib/services/site_icon_fetcher.dart` - Fetches and decodes the declared links (ICON-013), and `pageIconSource`, which of that and the webview's icon a site takes (ICON-014)
- `android/.../SiteIconPlugin.kt` - Turns on WebView favicon downloads

### Modified
- `lib/screens/add_site.dart` - UnifiedFaviconImage widget, SVG support
- `lib/screens/webspace_detail.dart` - Icons in site selection
- `pubspec.yaml` - Added `flutter_svg: ^2.0.10+1`
