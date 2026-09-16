## ADDED Requirements

### Requirement: US-DR-005 - The privileged bridge is granted per script, not implied

Enabling a user script says "run my code". It does not say "stop enforcing this
site's CSP and same-origin policy", and until this requirement the two were the
same act: any site with any enabled user script got the shim, and with it every
script on that page — the site's own, a third-party tag, an XSS payload — got
CSP-exempt execution through the inline bridge and cross-origin reads through
`window.__wsFetch`.

The bridge cannot be scoped to the script that wanted it. Its wrappers sit on
the page's own prototypes and its entry points are page-realm globals, so
whoever shares the document shares the capability. What can be scoped is
*whether the site has it at all*. `UserScriptConfig` SHALL therefore carry a
`bypassSitePolicy` flag, and the shim and all three Dart handlers SHALL be
installed only when the site has an **enabled** script that sets it. A site
whose scripts do not set it keeps native CSP and same-origin enforcement, and
the handlers are never registered — an unregistered handler cannot be reached
by a caller that guesses its name.

New scripts SHALL default to off. A script stored before the flag existed SHALL
inherit `true` when it is library-backed (a `url` or cached `urlSource`), which
is the case the bridge was built for (US-DR-001), and `false` otherwise: a
plain script keeps the CSP it should never have been costing the user.

The flag SHALL be editable in the script editor, ride `toJson` (and so settings
backup, US-005), and be presented with what it costs — the weakening applies to
the whole page, not to the one script.

#### Scenario: An ordinary user script does not weaken the site

**Given** a site with an enabled user script that does not set `bypassSitePolicy`
**When** the webview is built
**Then** no shim is injected and no bridge handler is registered
**And** the script itself still runs

#### Scenario: A library-backed script keeps working across the upgrade

**Given** a stored script with a cached `urlSource` and no `bypassSitePolicy` key
**When** it is loaded from JSON
**Then** `bypassSitePolicy` reads `true`

#### Scenario: A disabled script cannot arm the bridge

**Given** the only script setting `bypassSitePolicy` is disabled
**When** the webview is built
**Then** the bridge is not installed

### Requirement: US-DR-006 - `window.fetch` is left alone

The shim SHALL NOT replace `window.fetch`. It previously wrapped it to retry a
cross-origin `TypeError` through `__wsFetch` and answer with the body, which
made every same-origin-policy refusal and every `connect-src` the site set
unenforceable for all page script, without anything asking for it. The retry
was also lossy — it could not carry the original method, headers or body, so a
refused `POST` came back as the response to a `GET` the server saw twice.

A library that wants the bridged fetch is handed it by name
(`MyLib.setFetchMethod(window.__wsFetch)`), which is the documented route and
is unaffected.

#### Scenario: A cross-origin read the browser refuses stays refused

**Given** a site with the bridge installed and a CSP of `connect-src 'none'`
**When** page script calls `fetch` for a cross-origin URL
**Then** the call rejects and nothing is re-issued through the bridge

#### Scenario: A user script's library still reaches the bridge

**Given** the same site
**When** a script calls `window.__wsFetch` for that URL
**Then** the body is returned

---

### Requirement: US-DR-007 - A name is checked against what it resolves to

`classifyScriptFetchUrl` reads the URL string, so it refuses
`http://127.0.0.1/` and lets `http://evil.example/` through — the same
destination, spelled differently. A hostname whose A record names a loopback
or LAN address defeated the whole SSRF guard, and the bridge is reachable by
any script on a page that has it.

Where the app is the one resolving the destination, the host SHALL be resolved
before the connection and refused when **any** address it names is in a range
`isPrivateOrLoopbackHost` rejects. This SHALL apply to the initial URL and to
every redirect hop, on all three seams: the `__wsFetch` handler, the script
handler, and the editor's URL-source download.

A name that does not resolve SHALL be refused; the connection would use the
same resolver and fail anyway. A build with no resolver at all (web) SHALL be
allowed through — it has no webview and so no page script to drive this.

The check SHALL be applied **before** the script handler's confirmation
prompt, never as part of it: the dialog shows a URL, and
`http://cdn.evil.example/lib.js` reads as a CDN whatever it resolves to, so a
user cannot be the one to catch this.

The check SHALL NOT be applied under a SOCKS5 or Tor proxy, or an HTTP proxy.
Those resolve the destination at the far end by design, so what this device's
resolver answers describes a network the request never traverses — and a Tor
user has no local resolver to consult.

**Residual.** An answer can change between this lookup and the client's own
(a short-TTL flip). Closing that needs the connection pinned to the address
checked, which the `http` client does not expose.

#### Scenario: A hostname resolving onto loopback is refused

**Given** a page calls `window.__wsFetch('http://localtest.me/admin')`
**And** `localtest.me` resolves to `127.0.0.1`
**When** the bridge handles it
**Then** the handler returns `{status: 403}` and no request is issued

#### Scenario: One private address among public ones is enough

**Given** a host that resolves to both a routable address and `10.1.2.3`
**When** the bridge handles a fetch for it
**Then** it is refused

#### Scenario: A rebinding host never reaches the confirmation prompt

**Given** the script handler is asked to fetch `http://cdn.evil.example/lib.js`
**And** that name resolves to `127.0.0.1`
**When** the handler classifies it
**Then** it is refused and the user is not prompted

#### Scenario: A redirect onto a rebinding host is refused

**Given** a public URL answers `302 Location: http://localtest.me/admin`
**And** `localtest.me` resolves to `127.0.0.1`
**When** the bridge handles the redirect
**Then** it returns `{status: 403}` and the hop is not requested

#### Scenario: Remote-DNS proxies are exempt

**Given** the site's effective proxy is SOCKS5 or Tor
**When** the bridge fetches any host
**Then** no local resolution is consulted and the fetch proceeds

---

## MODIFIED Requirements

### Requirement: US-006 - Redirects are re-classified, not followed blindly

`classifyScriptFetchUrl` only ever sees the URL the caller hands in, and
`window.__wsFetch` is a page-reachable global that any third-party page script
can drive. The bridge's fetches SHALL therefore disable the HTTP client's
automatic redirect following, and SHALL re-run the gate that admitted the
original URL against every `Location` before requesting it, over a bounded
number of hops (5).

The gate re-run is the one the path uses for its first URL: the `__wsFetch`
handler refuses only `blocked` targets, while the script handler additionally
requires confirmation for a target off the CDN whitelist — a whitelisted CDN
must not be able to hand execution to an origin the user never approved.
`fetchUserScriptSource` (the editor's URL-source download) applies the
`__wsFetch` rule.

This closes the redirect half of the SSRF guard. The DNS-rebinding half is
closed by US-DR-007, whose resolution runs as part of this same re-run, so a
redirect onto a name pointing at a private address is refused by both halves.

#### Scenario: Redirect onto a cloud metadata endpoint

**Given** a page calls `window.__wsFetch('https://evil.example/hop')`
**And** `https://evil.example/hop` answers
`302 Location: http://169.254.169.254/latest/meta-data/`
**When** the bridge handles the redirect
**Then** the handler returns `{status: 403}`
**And** no request is issued to `169.254.169.254`

#### Scenario: Redirect onto a public host is followed

**Given** a page calls `window.__wsFetch('https://a.example/x')`
**And** that URL answers `302 Location: https://b.example/y`
**When** the bridge handles the redirect
**Then** `https://b.example/y` is requested and its body returned

#### Scenario: Whitelisted CDN redirects off the whitelist

**Given** a script element points at a whitelisted CDN URL
**And** that URL answers `302 Location: https://elsewhere.example/x.js`
**When** the script handler handles the redirect
**Then** the user is asked to confirm `https://elsewhere.example/x.js`
**And** nothing is injected unless they approve it

#### Scenario: Redirect chain is bounded

**Given** a host that answers every request with another redirect
**When** the bridge follows the chain
**Then** it stops after 5 hops and returns `{status: 403}`
