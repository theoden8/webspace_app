## MODIFIED Requirements

### Requirement: ICON-009 - Page Icon From the Site's Own Webview

On Android, the icon the site's own root webview reports through
`WebChromeClient.onReceivedIcon` SHALL be preferred over every fetched
candidate (ICON-002) while it is present, and no fetch SHALL run for the site
while it is present. It is fetched by the webview itself, so it goes through
the site's container and proxy and names no third party.

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
incognito, see [archive](../../../../specs/archive/spec.md) ARCH-006); otherwise it lives for
the session. An entry loaded from disk yields to the first icon of a launch
that is at least as large, so an icon the site has since dropped heals on the
next launch; within a launch only a larger icon replaces it, so pages of one
site with different icons do not flip it. `FaviconUrlCache.invalidate` (the
edit dialog's refresh, archive close and move) removes it, and the startup,
post-import and post-delete sweeps drop files for sites no longer kept on disk.

WKWebView has no public API for a page's icon, and the SPI that has one
(`_WKIconLoadingDelegate`) cannot ship through the App Store (guideline
2.5.1), so iOS and macOS keep the ICON-002 sources. WPE WebKit has no favicon
property either.

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
