# Icon Fetching Specification

## Purpose

Comprehensive icon fetching system for the Webspace app that provides high-quality favicons through multiple sources, progressive loading, and intelligent selection.

A user-set custom icon (`WebViewModel.customIconPng`, see EDIT-008 in
[site-editing](../site-editing/spec.md)) takes precedence over every fetched
source: when present, `UnifiedFaviconImage` renders it directly and skips
fetching entirely.

## Status

- **Date**: 2026-01-25
- **Status**: Completed

---

## Requirements

### Requirement: ICON-001 - Progressive Icon Loading

Icons SHALL load progressively instead of waiting for all sources to complete.

#### Scenario: Show icon quickly and upgrade

**Given** a user adds a site
**When** the icon is being fetched
**Then** a low-resolution icon appears within 1-2 seconds (DuckDuckGo ~64px)
**And** the icon upgrades to higher resolution as better versions are found

---

### Requirement: ICON-002 - Multiple Icon Sources

The system SHALL fetch icons from multiple sources in parallel:

1. DuckDuckGo (fast, ~64px)
2. Google Favicons (128px, 256px)
3. HTML parsing (native icons from page)
4. /favicon.ico fallback

#### Scenario: Select best available icon

**Given** DuckDuckGo returns a 64px icon
**And** Google returns a 256px icon
**And** HTML parsing finds a 1000px colored SVG
**When** selection is made
**Then** the SVG is chosen (highest quality score: 1000)

---

### Requirement: ICON-003 - Quality Scoring System

Icons SHALL be scored based on quality:

| Score | Type |
|-------|------|
| 1000 | Colored SVG icons (scale-invariant) |
| 256 | Google 256px (colored, high-res) |
| 128 | Google 128px, HTML high-res icons |
| 64 | DuckDuckGo (colored) |
| 50 | Monochrome SVG icons |
| 32 | /favicon.ico fallback |
| 16 | HTML unknown size icons |

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
**Then** the SVG is marked as monochrome (quality 50)

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

### Requirement: ICON-006 - Smart Public Service Filtering

Google and DuckDuckGo icon services SHALL be skipped for:
- every site while Site icons only is on (ICON-014)
- http:// sites (non-HTTPS)
- IPv4 addresses (e.g., 192.168.1.1)
- IPv6 addresses (e.g., [::1])
- localhost

#### Scenario: Skip public services for local server

**Given** a user adds "http://192.168.1.100:8080"
**When** icons are fetched
**Then** DuckDuckGo and Google services are not queried
**And** only direct favicon fetch and HTML parsing are used

---

### Requirement: ICON-007 - Domain Substitution

The system SHALL support domain substitution for better icon quality.

```dart
const Map<String, String> _domainSubstitutions = {
  'gmail.com': 'mail.google.com',
};
```

#### Scenario: Substitute gmail.com domain

**Given** a user adds gmail.com
**When** icons are fetched
**Then** icons are fetched from mail.google.com instead

---

### Requirement: ICON-008 - Icon Caching

Fetched icons SHALL be cached to avoid redundant network requests.

#### Scenario: Return cached icon

**Given** an icon was fetched for example.com 5 minutes ago
**When** the icon is requested again
**Then** the cached result is returned immediately

#### Scenario: Page refresh does not invalidate icon cache

**Given** a site has a cached favicon
**When** the user refreshes the page from the nav bar
**Then** only the page is reloaded
**And** the cached favicon is NOT re-fetched

#### Scenario: Drawer refresh invalidates icon cache

**Given** a site has a cached favicon
**When** the user taps the refresh button in the drawer site list
**Then** the favicon cache is invalidated and the icon is re-fetched
**And** the page title is also refreshed

---

### Requirement: ICON-009 - Page Icon From the Site's Own Webview

On Android, the icon the site's own root webview reports through
`WebChromeClient.onReceivedIcon` SHALL be preferred over every fetched
candidate (ICON-002) while it is present, and no ICON-002 fetch SHALL run for
the site while it is present. It is fetched by the webview itself, so it goes
through the site's container and proxy and names no third party.

The callback carries a bitmap and nothing else: no URL, no document. Chromium's
WebView downloads every `rel=icon` candidate, so it fires once per candidate in
download-completion order, again whenever the page edits its icon links, and
for whatever document is loaded. `SiteIconEngine` therefore takes an icon only
when all of these hold:

- no main-frame load is in flight (Blink announces a document's icons only
  after its load event, so an icon arriving mid-load belongs to the document
  being replaced);
- the loaded document is http(s) and on the site's host, with a leading `www.`
  folded (sharing the registrable domain is not enough: a login bounce to
  `accounts.example.com` shows that host's icon, not the site's);
- the page has not edited its icon links since load (ICON-011);
- it is at least the ICON-010 floor and larger than any icon this document
  already produced.

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
2.5.1). WPE WebKit has no favicon property either. On iOS, macOS and Linux
the app fetches the icon links the page declared instead (ICON-013), and the
result is kept and preferred exactly as above.

#### Scenario: Largest icon of the page wins

**Given** a site page declares 16px, 32px and 192px icons
**And** they finish downloading in the order 32, 192, 16
**When** the webview reports each of them
**Then** the site's icon is the 192px one
**And** the 16px icon is never taken

#### Scenario: Another host's icon is not the site's

**Given** a site whose home is `https://mail.example.com/`
**When** the webview lands on `https://accounts.example.com/login` and reports
its icon
**Then** the site's icon does not change

#### Scenario: Preferred over fetched candidates

**Given** the site's webview has reported a 64px icon
**And** Google's service would return a 256px icon
**When** the drawer renders the site
**Then** it shows the webview's icon
**And** no request goes to Google or DuckDuckGo for the site

#### Scenario: Incognito icon does not reach disk

**Given** an incognito or archive-tier site
**When** its webview reports an icon
**Then** the drawer shows it for the session
**And** nothing is written under the app's `site_icons` directory

---

### Requirement: ICON-010 - Page Icon Preference Floor

An icon from the webview SHALL be taken only when both edges are at least
32px. Below that, the fetched candidates (up to 256px) look better in the
drawer than an upscaled 16px `favicon.ico` frame.

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

On iOS, macOS and Linux, where the webview reports no icon, and on Android
under Site icons only (ICON-014), the app SHALL fetch the icon links the top
document declared at load, and SHALL apply ICON-009's host, size and store
rules and ICON-010's floor to them. `pageIconSource` decides which of the two
a site's webview uses when the webview is created.

It overlaps ICON-002, which already reads the home page's HTML through the
site's proxy. What it adds: the links of the page actually shown, where a
cookie-less fetch of the home URL meets a bot wall, a sign-in redirect or a
script-set icon (6 of the 17 suggested sites that loaded in a 2026-09 probe),
and the page's own icon winning over the public services. The cost: most
sites declare only small icons (a `favicon.ico`, 32 to 48px), so at the
ICON-010 floor a site's own icon can displace a larger and sharper
public-service one. It ran as the Page icons experiment first; on device it
found the icon a site's pages declare once each page had loaded.

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

While the Site icons only experiment is on ([developer-tools](../developer-tools/spec.md)
DEVTOOLS-011: developer mode and its own switch, off by default, listed on
every platform), a site's icon SHALL come only from the site itself:

- **No third-party service.** Google's and DuckDuckGo's icon services
  (ICON-002 sources 1 and 2) SHALL NOT be asked, on any path that fetches an
  icon: the drawer, the add-site preview, the home shortcut export.
  `publicIconServicesAllowed` in `icon_service.dart` is the one gate, read on
  every fetch and again before each service is asked and when each answers,
  so a fetch already running when the switch goes on neither shows nor keeps
  a service's icon. The icon widget cancels a fetch it restarts rather than
  letting the old one keep writing into it. What is left is ICON-013's declared links and ICON-002's page
  scrape and `/favicon.ico`, which go to the site's host through its proxy.
- **Nothing resolved earlier.** A service URL resolved before the switch went
  on, in the icon service's memory or in `FaviconUrlCache` on disk, SHALL read
  as absent (`usableIconUrl`), so the icon is fetched again from the site.
  Turning the switch or developer mode on or off calls
  `notifyIconSourcesChanged`, and an icon on screen that came from a service
  no longer allowed is fetched again at once.
- **Android like the rest.** On Android the site's webview SHALL fetch the
  declared links as ICON-013 describes, SHALL NOT take `onReceivedIcon`'s
  icons, and SHALL NOT turn on WebView's favicon downloads for it. The load
  report (`wsIconDocumentLoaded`) SHALL never run beside `onReceivedIcon`: it
  reaches Dart through a posted Java message that the callback can overtake
  (ICON-009). The link report rides the same bridge after the load report,
  in order, so the two cannot swap.

The page-icon source is read when a site's webview is created, so a change
applies to sites opened afterwards. A site that declares only small icons
shows a smaller one, or the scrape's, or the placeholder.

#### Scenario: No request to a third party

**Given** Site icons only is on
**When** the icon of `https://example.com/` is fetched
**Then** every request goes to `example.com`
**And** none goes to `www.google.com` or `icons.duckduckgo.com`

#### Scenario: A service icon found earlier is fetched again

**Given** a site whose icon came from Google's service
**When** the user turns Site icons only on
**Then** the icon on screen is fetched again from the site
**And** the Google URL kept on disk is not used

#### Scenario: A fetch already running when the switch goes on

**Given** Site icons only is off and a site's icon is being fetched
**When** the user turns Site icons only on before the fetch ends
**Then** no service is asked after that
**And** no icon a service sends is shown, sent as the fetch's result, or kept

#### Scenario: Android takes the declared links

**Given** an Android build with Site icons only on
**And** a site page that declares 16px, 32px and 192px icons with `sizes`
**When** a site opened after the switch loads that page
**Then** the site's icon is the 192px one, fetched by the app
**And** no icon WebView reports for that site is taken

#### Scenario: Developer mode off gives the services back

**Given** Site icons only is on
**When** the user turns developer mode off
**Then** Google's and DuckDuckGo's services are asked again (DEVTOOLS-011)

---

### Requirement: ICON-015 - Reset Icon Cache

While developer mode is on, App settings SHALL offer **Reset icon cache**,
with its explanation behind a `HintButton`. It SHALL drop every icon the app
keeps: the resolved URLs and SVGs in `FaviconUrlCache`, the icons sites
reported in `SiteIconStore` (memory and disk), and the icon service's memory.
Every icon on screen is then fetched again (`reloadAllIcons`), and a site's
own icon returns once the site loads again. It is how a change of icon source
(ICON-014) is checked without reinstalling.

#### Scenario: Every cached icon goes, nothing else does

**Given** developer mode is on, a resolved icon URL and SVG are cached, and a
site has a reported icon on disk
**When** the user taps Reset icon cache
**Then** no `favicon_` pref and no stored site icon remains
**And** no other pref changes
**And** a confirmation says the icon cache was cleared

---

## Performance

- **Before**: Users waited 10-15 seconds seeing a spinner
- **After**: Icons appear within 1-2 seconds, then upgrade as better versions load

---

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
