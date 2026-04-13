# Gemini Protocol Support

## ADDED Requirements

### Requirement: GEMINI-001 - Recognize Gemini URL Scheme

The system SHALL accept `gemini://` URLs in Add Site screen, URL bar, and site editing dialog. When this scheme is detected, the system SHALL NOT prepend `https://`.

#### Scenario: Enter Gemini URL in Add Site

**Given** the user is on the Add Site screen
**When** the user enters `gemini://geminiprotocol.net`
**Then** the URL is accepted as-is without prepending `https://`
**And** the site is created with the `gemini://` scheme preserved

---

### Requirement: GEMINI-002 - Native Gemini Client

The system SHALL implement a Gemini protocol client in Dart that opens a TLS connection on port 1965, sends the URL, reads the response status and body, and handles redirects (3x status) up to 5 hops.

#### Scenario: Fetch Gemini page successfully

**Given** a Gemini server is running at `gemini://example.com`
**When** the client connects via TLS on port 1965
**And** sends `gemini://example.com/\r\n`
**Then** the response status `20 text/gemini` is received
**And** the body content is returned

#### Scenario: Follow Gemini redirect

**Given** a Gemini server returns status `30 gemini://example.com/new-page`
**When** the client receives the redirect
**Then** the client follows the redirect to the new URL
**And** stops after 5 redirect hops maximum

---

### Requirement: GEMINI-003 - TLS with TOFU

The Gemini client SHALL use Trust On First Use certificate validation, storing fingerprints per hostname via SharedPreferences.

#### Scenario: First visit to Gemini server

**Given** the user visits `gemini://example.com` for the first time
**When** the TLS connection is established
**Then** the server's certificate fingerprint is stored
**And** the page loads successfully

#### Scenario: Certificate change detected

**Given** the user has previously visited `gemini://example.com`
**When** the server presents a different certificate
**Then** a warning is shown to the user
**And** the user can accept or reject the new certificate

---

### Requirement: GEMINI-004 - Gemtext-to-HTML Rendering

The system SHALL convert `text/gemini` content to styled HTML, parsing headings, links, lists, preformatted blocks, and quotes. The CSS theme SHALL respect the app's light/dark mode.

#### Scenario: Render gemtext with headings and links

**Given** Gemini content contains `# Title` and `=> gemini://other.com Link text`
**When** the content is rendered
**Then** the heading appears as an HTML `<h1>` element
**And** the link appears as a clickable `<a>` tag

#### Scenario: Render preformatted block

**Given** Gemini content contains a block between ``` markers
**When** the content is rendered
**Then** the block appears in monospace font with horizontal scroll

---

### Requirement: GEMINI-005 - Webview Content Loading

The system SHALL render Gemini content using `loadHtmlString()` with `mimeType: 'text/html'` and the original `gemini://` URL as `baseUrl`.

#### Scenario: Load rendered Gemini content in webview

**Given** Gemini content has been fetched and converted to HTML
**When** the HTML is loaded into the webview
**Then** the content displays correctly
**And** the URL bar shows the original `gemini://` URL

---

### Requirement: GEMINI-006 - Navigation Interception

When a user clicks a `gemini://` link within rendered content, the navigation SHALL be intercepted, the Gemini client SHALL fetch the linked content, and the webview SHALL be updated with the new rendered HTML.

#### Scenario: Click Gemini link in rendered content

**Given** a rendered Gemini page contains a link to `gemini://other.com/page`
**When** the user clicks the link
**Then** the Gemini client fetches the linked page
**And** the webview is updated with the newly rendered HTML
**And** the URL bar shows `gemini://other.com/page`

---

### Requirement: GEMINI-007 - Skip DNS Validation

The Add Site preview SHALL skip standard DNS lookup for `gemini://` URLs and instead attempt a Gemini connection to validate reachability.

#### Scenario: Validate Gemini site by connection

**Given** the user adds a site with URL `gemini://example.com`
**When** validation runs
**Then** DNS lookup is skipped
**And** a Gemini connection attempt is used to verify the server

---

### Requirement: GEMINI-008 - Disable Inapplicable Features

For Gemini sites, JavaScript injection, cookie management, content blockers, DNS blocklist, ClearURLs, and proxy settings SHALL be disabled or hidden.

#### Scenario: Hide JavaScript settings for Gemini site

**Given** a site is configured with a `gemini://` URL
**When** the user opens site settings
**Then** user scripts and JavaScript options are not shown
**And** cookie management options are not shown

---

### Requirement: GEMINI-009 - Domain Comparison

Gemini sites SHALL participate in domain comparison using the hostname from the `gemini://` URL. Cookie isolation is inherently satisfied since Gemini has no cookies.

#### Scenario: Gemini site domain extraction

**Given** a site has URL `gemini://example.com/page`
**When** domain comparison is performed
**Then** the hostname `example.com` is extracted and used
**And** no cookie conflict handling is needed
