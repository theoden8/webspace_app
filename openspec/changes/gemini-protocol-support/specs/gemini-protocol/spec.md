# Gemini Protocol Support

## ADDED Requirements

### Requirement: GEMINI-001 - A Gemini capsule is a site

The system SHALL accept a `gemini://` URL wherever a site URL is entered (Add
Site, site editing, the URL bar) and keep the scheme: `ensureUrlScheme` SHALL
NOT prepend `https://`. The site is a site in every other respect: it has a
`siteId`, a container and a `SitePosture`, and it rides the site list, backups
and QR codes as its URL string.

The Add Site preview SHALL NOT probe the device's resolver for a Gemini host:
a capsule may sit behind the site's proxy, and an onion capsule must
(LEAK-016).

#### Scenario: Add a capsule

**Given** the user is on Add Site
**When** they enter `gemini://geminiprotocol.net/`
**Then** the site is created with that URL, scheme kept
**And** no local DNS lookup is made for `geminiprotocol.net`

---

### Requirement: GEMINI-002 - A Gemini request rides the site's route

Every Gemini request SHALL go out on the site's effective proxy
(`resolveEffectiveProxy`), as every Dart-side fetch does (LEAK-002): through
SOCKS5 or Tor with the destination name sent to the proxy, or through an HTTP
or HTTPS proxy with `CONNECT host:port`. A route the client cannot carry SHALL
refuse the request, never fall back to a direct connection. An onion capsule
on a route with no proxy SHALL be refused before anything resolves its name
(LEAK-016).

The client is a new outbound seam and SHALL have its row in the LEAK-007
coverage matrix.

#### Scenario: A capsule behind Tor

**Given** a site `gemini://example.org/` whose proxy is `TOR`
**When** the page is fetched
**Then** the TLS session runs inside a Tor stream tagged with the site's
isolation credential (TOR-003)
**And** the device's resolver is not asked for `example.org`

#### Scenario: A route the client cannot carry

**Given** the site's proxy names a saved proxy that no longer resolves
**When** the page is fetched
**Then** no connection is made
**And** the page says the request was not sent, naming the proxy setting

---

### Requirement: GEMINI-003 - One request, bounded

A request SHALL be the URL (at most 1024 bytes) followed by CRLF, on port 1965
unless the URL names another. The response header SHALL be read up to 1029
bytes, and the body up to a size cap; a response past either is cut and
reported, not rendered in part as if whole. Redirects (3x) SHALL be followed
up to 5 hops, each hop on the same route and through the same gate as the
first, and a redirect to another scheme SHALL NOT be followed by the client.

#### Scenario: Redirect to another host

**Given** a capsule answers `31 gemini://other.example/`
**When** the client follows it
**Then** `other.example` is asked on the same route, as a new request

#### Scenario: Redirect off Gemini

**Given** a capsule answers `30 https://example.com/`
**When** the client reads it
**Then** it does not fetch `https://example.com/`
**And** the page offers the link for the navigation gate to decide

---

### Requirement: GEMINI-004 - A capsule's certificate is pinned on first use

Gemini servers present self-signed certificates by convention. The first
successful TLS session with a `(host, port)` SHALL pin the certificate's
SHA-256 in the store `TrustedHostsService` keeps (TLS-007: never written to a
backup). A later session presenting another certificate SHALL NOT load, and
SHALL show the rotation prompt TLS-005 shows for a changed pin; it is never
re-pinned silently. An archive-tier site SHALL keep its pins only for the
session, never on disk (ARCH-006).

#### Scenario: First visit

**Given** no pin exists for `example.org:1965`
**When** the capsule's first page loads
**Then** its certificate fingerprint is pinned

#### Scenario: The certificate changed

**Given** a pin exists for `example.org:1965`
**When** the server presents a different certificate
**Then** nothing is rendered from that session
**And** the user is asked whether to trust the new certificate

---

### Requirement: GEMINI-005 - Gemtext renders as inert HTML

`text/gemini` SHALL be converted to HTML by a pure engine: headings, links,
list items, quotes, preformatted blocks and text lines. Every byte that comes
from the capsule SHALL be escaped; a link's URL SHALL be resolved against the
page and emitted only as an `href`. The rendered document SHALL carry a
Content-Security-Policy that allows no script and no network fetch, and SHALL
be styled from the site's theme (follow the app's or its own). Other text
types render as preformatted text; any other type is offered as a download
under the site's download rules and never rendered.

#### Scenario: A hostile line

**Given** a gemtext line `<script>alert(1)</script>`
**When** it is rendered
**Then** it appears as text
**And** no script runs in the site's webview

#### Scenario: Dark theme

**Given** the site follows the app's theme and the app is dark
**When** a capsule renders
**Then** the page uses the dark palette

---

### Requirement: GEMINI-006 - Gemini links navigate through the gate

A navigation to a `gemini://` URL in a site's webview, the site's own first
load among them, SHALL be cancelled and served by the client, the result
loaded into the same webview as data with the `gemini://` URL as its base, so
the URL bar and the back stack show the capsule's URL. The navigation SHALL
first pass the same routing decision and coverage gate as any other
(LEAK-010, LEAK-016): a link to another host is routed as cross-domain links
are, and a nested screen serves Gemini the same way under the site's posture.
A link to any other scheme from a rendered capsule SHALL take the path it
takes today.

#### Scenario: Follow a link inside a capsule

**Given** a rendered page links `gemini://example.org/next`
**When** the user taps it
**Then** the client fetches it on the site's route
**And** the URL bar shows `gemini://example.org/next`
**And** going back shows the previous page

#### Scenario: An https link out of a capsule

**Given** a rendered page links `https://example.com/`
**When** the user taps it
**Then** the link is routed as any cross-domain https link is

---

### Requirement: GEMINI-007 - Every status line has its page

The client's result SHALL be a sealed type with one case per status class, and
each SHALL render its own page:

| Status | Page |
|---|---|
| 10, 11 input | a text field (masked for 11) whose answer is sent as the URL's query |
| 20 success | the rendered body (GEMINI-005) |
| 30, 31 redirect | followed (GEMINI-003) |
| 40-44, 50-59 failure | the status and the server's message, with a retry for 4x |
| 60-62 certificate | that the capsule asks for a client certificate, which the app does not send |

A connection failure, a refused route and a cut response SHALL each be their
own case, and none SHALL read as the server's answer.

#### Scenario: Not found

**Given** a capsule answers `51 not found`
**When** the page renders
**Then** it says the server reported the page not found
**And** offers no retry

#### Scenario: Input

**Given** a capsule answers `10 Search terms`
**When** the user enters `onion routing`
**Then** the client requests the same URL with `?onion%20routing`
