## ADDED Requirements

### Requirement: NAV-011 - Site Info From The URL Bar

The URL bar SHALL end with an info button that opens a sheet saying which of
the user's sites the page on screen runs as and which container holds its data.
The button SHALL sit at the trailing end of the bar, so a right-to-left locale
puts it on the left, and SHALL give way to the Go button while the URL is being
edited. The nested screen's overflow menu SHALL carry the same entry, because
its URL bar can be hidden.

The sheet SHALL show:

- **Site**: the site whose settings and identity the webview carries. For a
  nested screen that is the site whose link opened it, or the site outbound
  routing picked (LIR-015).
- **Page**: the URL on screen.
- **Container**: the site's own container, with its `ws-<id>` name; a private
  store discarded on close (incognito off Android); or the store every site
  shares (the legacy engine).

The container SHALL be computed by `containerIdFor`, the same function
`WebViewFactory.createWebView` binds by, from the same inputs the webview's
`WebViewConfig` was given, so the sheet cannot name a container the webview
does not use.

#### Scenario: A routed page names the site it runs as

- **GIVEN** a DuckDuckGo site that routes `github.com` links to a GitHub site
- **WHEN** the user taps a GitHub link and then the info button of the nested screen
- **THEN** the sheet's Site row reads GitHub
- **AND** its Container row names the GitHub site's container

#### Scenario: An unrouted page names its source

- **GIVEN** a DuckDuckGo site in the in-app mode that does not route
- **WHEN** a tapped link opens a nested screen and the user opens its site info
- **THEN** the Site row reads DuckDuckGo and the Container row names DuckDuckGo's container

#### Scenario: Private and shared stores say so

- **GIVEN** an incognito site on iOS, macOS or Linux
- **THEN** its sheet's Container row reads "Private, discarded when closed" with no container name
- **AND** on the legacy engine the row reads "Shared, cookies swapped per site"

#### Scenario: The button follows the text direction

- **GIVEN** the app in a right-to-left locale
- **THEN** the info button sits left of the address field
- **AND** while the address is being edited the Go button takes its place
