# IPFS Protocol Support

## ADDED Requirements

### Requirement: IPFS-001 - Recognize IPFS/IPNS URL Schemes

The system SHALL accept `ipfs://` and `ipns://` URLs in Add Site screen, URL bar, and site editing dialog. When these schemes are detected, the system SHALL NOT prepend `https://`.

#### Scenario: Enter IPFS URL in Add Site

**Given** the user is on the Add Site screen
**When** the user enters `ipfs://QmExample123` as the URL
**Then** the URL is accepted as-is without prepending `https://`
**And** the site is created with the `ipfs://` scheme preserved

#### Scenario: Enter IPNS URL in URL bar

**Given** a site is loaded
**When** the user types `ipns://example.eth` in the URL bar and submits
**Then** the URL is accepted as-is without prepending `https://`

---

### Requirement: IPFS-002 - Gateway URL Rewriting

The system SHALL rewrite IPFS/IPNS URLs to HTTP gateway URLs before loading in the webview. The gateway base URL is configurable (default: `https://ipfs.io`).

#### Scenario: Load IPFS content via gateway

**Given** a site has URL `ipfs://QmExample123/page.html`
**When** the webview loads the site
**Then** the actual request is made to `https://ipfs.io/ipfs/QmExample123/page.html`
**And** the page content is displayed in the webview

#### Scenario: Load IPNS content via gateway

**Given** a site has URL `ipns://example.eth`
**When** the webview loads the site
**Then** the actual request is made to `https://ipfs.io/ipns/example.eth`

---

### Requirement: IPFS-003 - URL Bar Display

The URL bar SHALL display the original `ipfs://` or `ipns://` URL, not the gateway-rewritten URL, when the user is viewing IPFS content.

#### Scenario: URL bar shows IPFS URL

**Given** a site was added with URL `ipfs://QmExample123`
**When** the page is loaded via the gateway
**Then** the URL bar displays `ipfs://QmExample123`
**And** a distinct icon indicates IPFS gateway content

---

### Requirement: IPFS-004 - Navigation Interception

When a user clicks an `ipfs://` or `ipns://` link within a loaded page, `shouldOverrideUrlLoading` SHALL intercept it and apply gateway rewriting.

#### Scenario: Click IPFS link on a page

**Given** a page is loaded that contains an `ipfs://` link
**When** the user clicks the link
**Then** the navigation is intercepted
**And** the link is rewritten to the configured gateway URL
**And** the rewritten URL is loaded in the webview

---

### Requirement: IPFS-005 - Skip DNS Validation

The Add Site preview/validation SHALL skip DNS lookup for `ipfs://` and `ipns://` URLs.

#### Scenario: Add IPFS site without DNS validation

**Given** the user is adding a site with URL `ipfs://QmExample123`
**When** the URL is validated
**Then** DNS lookup is skipped
**And** the site is accepted

---

### Requirement: IPFS-006 - Configurable Gateway URL

The app SHALL provide a global setting for the IPFS gateway base URL, persisted via SharedPreferences.

#### Scenario: Change gateway URL

**Given** the user opens app settings
**When** the user changes the IPFS gateway to `https://dweb.link`
**And** loads an IPFS site
**Then** the request is made to `https://dweb.link/ipfs/<CID>`

---

### Requirement: IPFS-007 - Domain Comparison Exemption

IPFS/IPNS URLs SHALL be exempted from domain-comparison logic used for cookie isolation and nested webview decisions.

#### Scenario: IPFS sites bypass domain conflict detection

**Given** two IPFS sites exist with different CIDs
**When** the user switches between them
**Then** no domain conflict is detected
**And** both sites can be loaded without cookie isolation issues
