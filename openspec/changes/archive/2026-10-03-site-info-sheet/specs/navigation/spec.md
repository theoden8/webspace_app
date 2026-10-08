## ADDED Requirements

### Requirement: NAV-011 - Site Info From The URL Bar

The URL bar SHALL end with an info button that opens a sheet saying which of
the user's sites the page on screen runs as and which container holds its data.
The button SHALL sit at the trailing end of the bar, so a right-to-left locale
puts it on the left, and SHALL give way to the Go button while the URL is being
edited. The URL bar SHALL be the only way to the sheet: no overflow menu SHALL
carry it, the nested screen's included.

The sheet SHALL show:

- **Site**: the site whose settings and identity the webview carries. For a
  nested screen that is the site whose link opened it, or the site outbound
  routing picked (LIR-015). For a hosted tab it is the host (LIR-018).
- **Tab of**, for a hosted tab only: the site whose tab list holds it.
- **Opened from**, for a nested screen that runs as a site other than the one
  on screen when it opened: that site.
- **Page**: the URL on screen.
- **Container**: the named site's own container, "{site}'s own container" with
  its `ws-<id>` name; a private store discarded on close (incognito off
  Android); or the store every site shares (the legacy engine). The row SHALL
  name the site rather than say "this site": with a page on one site's address
  running as another, "this site" does not say which.

The container SHALL be computed by `containerIdFor`, the same function
`WebViewFactory.createWebView` binds by, from the same inputs the webview's
`WebViewConfig` was given, so the sheet cannot name a container the webview
does not use.

#### Scenario: A routed page names the site it runs as

- **GIVEN** Site tabs are off and a DuckDuckGo site routes `github.com` links to a GitHub site
- **WHEN** the user taps a GitHub link and then the info button of the nested screen
- **THEN** the sheet's Site row reads GitHub and its Opened from row reads DuckDuckGo
- **AND** its Container row reads "GitHub's own container"

#### Scenario: An unrouted page names its source

- **GIVEN** a DuckDuckGo site in the in-app mode that does not route
- **WHEN** a tapped link to a site the user does not have opens a nested screen and the user opens its site info
- **THEN** the Site row reads DuckDuckGo, there is no Opened from row, and the Container row reads "DuckDuckGo's own container"

#### Scenario: A hosted tab names both sites

- **GIVEN** a GitHub tab in DuckDuckGo's tab list, running as GitHub
- **WHEN** the user opens its site info
- **THEN** the Site row reads GitHub, the Tab of row reads DuckDuckGo
- **AND** the Container row reads "GitHub's own container"

#### Scenario: Private and shared stores say so

- **GIVEN** an incognito site on iOS, macOS or Linux
- **THEN** its sheet's Container row reads "Private, discarded when closed" with no container name
- **AND** on the legacy engine the row reads "Shared, cookies swapped per site"

#### Scenario: The button follows the text direction

- **GIVEN** the app in a right-to-left locale
- **THEN** the info button sits left of the address field
- **AND** while the address is being edited the Go button takes its place
