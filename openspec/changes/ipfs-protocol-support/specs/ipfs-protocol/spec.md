# IPFS Protocol Support

## ADDED Requirements

### Requirement: IPFS-001 - An IPFS or IPNS URL is a site

The system SHALL accept `ipfs://` and `ipns://` URLs wherever a site URL is
entered (Add Site, site editing, the URL bar) and keep the scheme:
`ensureUrlScheme` SHALL NOT prepend `https://`. The Add Site preview SHALL NOT
probe the device's resolver for a CID or an IPNS name: neither is a host the
device would ask for.

#### Scenario: Add content by CID

**Given** the user is on Add Site
**When** they enter `ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/`
**Then** the site is created with that URL, scheme kept
**And** no local DNS lookup is made

---

### Requirement: IPFS-002 - The gateway URL is the subdomain form

An IPFS URL SHALL load from the configured gateway in its subdomain form, so
each CID or name has its own origin:

| Site URL | Loaded URL |
|---|---|
| `ipfs://<cid>/path?q` | `https://<cidv1-base32>.ipfs.<gateway>/path?q` |
| `ipns://<key>/path` | `https://<key-base36>.ipns.<gateway>/path` |
| `ipns://docs.example.org/p` | `https://docs-example-org.ipns.<gateway>/p` |

The scheme is `https`, except for a gateway on loopback, which a local node
serves over `http`.

A CIDv0 (`Qm...`) SHALL be converted to its CIDv1 in base32 first, since a
DNS label is case-insensitive. An IPNS DNSLink name SHALL be inlined: each
`-` doubled, then each `.` replaced by `-`. The conversion is a pure engine,
and a URL it cannot convert SHALL NOT load: the site shows that the address
is not a valid IPFS address, and the path form is never used instead.

#### Scenario: A CIDv0

**Given** a site `ipfs://QmT78zSuBmuS4z925WZfrqQ1qHaJ56DQaTfyMUF7F8ff5o/`
**When** it loads
**Then** the request goes to `https://bafybeicg2rebjoofv4kbyovkw7af3rpiitvnl6i7ckcywaq6xjcxnc2mby.ipfs.dweb.link/`

#### Scenario: Two CIDs do not share an origin

**Given** two IPFS sites with different CIDs
**When** both are loaded
**Then** each runs at its own origin
**And** neither can read the other's storage

---

### Requirement: IPFS-003 - The gateway is one setting, and it is told

The gateway SHALL be one `AppPref`, a host with an optional port, `dweb.link`
by default, edited in App Settings > Network. A local node is a gateway like
any other (`localhost:8080`). The row's hint SHALL say that the gateway
operator sees every CID and name the app loads through it, and the device's
IP unless the site's proxy hides it.

The gateway request is an https request of the site: it SHALL ride the site's
proxy, blockers and navigation gate exactly as any https navigation of that
site does.

#### Scenario: A site behind Tor

**Given** an IPFS site whose proxy is `TOR`
**When** it loads
**Then** the gateway request goes through the site's Tor circuit

#### Scenario: Changing the gateway

**Given** the gateway is changed to `localhost:8080`
**When** an IPFS site loads next
**Then** it loads from `http://<cidv1>.ipfs.localhost:8080/`

---

### Requirement: IPFS-004 - The URL bar shows the IPFS address

While an IPFS site shows a page from the configured gateway's subdomain form,
the URL bar, the site info sheet and anything that copies or shares the
current URL SHALL show the `ipfs://` or `ipns://` address. A page of any
other host SHALL show its own URL. The mapping back SHALL be the inverse of
IPFS-002, from the same engine.

#### Scenario: Share the current page

**Given** an IPFS site shows `https://<cid>.ipfs.dweb.link/docs/`
**When** the user shares the page
**Then** the shared URL is `ipfs://<cid>/docs/`

---

### Requirement: IPFS-005 - Each CID is its own site

`<x>.ipfs.<gateway>` and `<x>.ipns.<gateway>` SHALL each be their own site
for base-domain comparison, nested-navigation routing and site claims, as a
host under a private suffix is (the gateway's `ipfs.<gateway>` and
`ipns.<gateway>` are such suffixes). A link from one CID to another is a
cross-domain link.

#### Scenario: A link to another CID

**Given** an IPFS site shows content from one CID
**When** the user taps a link to a page of another CID on the same gateway
**Then** the navigation is routed as a cross-domain link

---

### Requirement: IPFS-006 - An IPFS link in a page is rewritten, then routed

A navigation to an `ipfs://` or `ipns://` URL from a page SHALL be cancelled
and reissued as its gateway URL (IPFS-002). The reissued navigation SHALL
take the same routing decision and coverage gate as any https navigation
(LEAK-010, LEAK-016), and is not exempt from the site's blockers.

#### Scenario: A link on a web page

**Given** an https site with a link to `ipfs://<cid>/`
**When** the user taps it
**Then** the link opens as the gateway URL, routed as a cross-domain link
