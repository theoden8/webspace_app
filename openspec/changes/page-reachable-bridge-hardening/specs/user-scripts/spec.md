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
