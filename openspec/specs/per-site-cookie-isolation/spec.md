# Per-Site Cookie Isolation

## Status
**Implemented (legacy / fallback path).**

> **Note:** This is the fallback engine, used when
> [`ContainerNative.isSupported()`](../../../lib/services/container_native.dart)
> is `false` — i.e. Windows, web, iOS <17, macOS <14, WPE WebKit
> <2.40, and an Android System WebView not reporting `MULTI_PROFILE`.
> Everywhere else the app uses native per-site profiles instead; see
> [openspec/specs/per-site-containers/spec.md](../per-site-containers/spec.md).
> Engine selection is a single cached `bool _useProfiles` in
> [`_WebSpacePageState`](../../../lib/main.dart) resolved at startup;
> none of the requirements below apply when `_useProfiles == true`
> (the conflict-find / unload-on-switch / capture-nuke-restore code
> path is skipped end-to-end in that mode).

## Purpose
Implements cookie isolation between sites on the same domain. This allows users to have multiple accounts (e.g., two GitHub accounts) as separate sites without session sharing.

**Formal model:** the legacy shared-jar invariant ("the jar always holds the visible site's cookies, never another site's") is composed into the cross-spec kernel [formal/kernel.tla](../../../formal/kernel.tla) as `Inv_JarMatchesVisible`; activating a site without capture-nuke-restore violates it (the `contaminate` demonstrator). Observable cookie-switch transitions are also checked against real `LogService` traces in [formal/trace/](../../../formal/trace/).

## Problem Statement

The `CookieManager` in `flutter_inappwebview` is a singleton that shares cookies across all webviews. When a user has multiple sites on the same domain (e.g., `github.com/personal` and `github.com/work`), they share the same session cookies, causing:

1. Automatic login to wrong account when switching sites
2. Inability to maintain separate sessions for work/personal accounts
3. Session conflicts when both sites are loaded

## Solution

Implement mutual exclusion: only ONE webview per second-level domain can be active at a time. When switching to a different site on the same domain:

1. Capture departing site's cookies from CookieManager
2. Store cookies on the departing WebViewModel (keyed by siteId)
3. Dispose departing site's webview
4. Clear CookieManager for the domain
5. Restore arriving site's stored cookies to CookieManager
6. Create arriving site's webview

## Requirements

### Requirement: ISO-001 - Mutual Exclusion

Only ONE webview per second-level domain SHALL be active at a time.

#### Scenario: Activate site on occupied domain

**Given** Site A (`github.com/personal`) is currently active
**And** Site B (`github.com/work`) exists
**When** the user selects Site B
**Then** Site A's webview is disposed
**And** Site B's webview is created

### Requirement: ISO-002 - Cookie Capture on Unload

The system SHALL capture cookies before unloading a webview, whatever the
reason it is unloaded (domain conflict, webspace switch, proxy or Tor
exit-country mismatch, the loaded-site cap, memory pressure, a home reset).
Every activation empties the shared jar after saving it for the loaded sites
only, so a site unloaded without the capture loses what it set since its own
activation. All unloads go through `SiteUnloadEngine.unloadFlow`.

#### Scenario: Capture cookies before switch

**Given** Site A is active with session cookies
**When** Site A is unloaded due to domain conflict
**Then** Site A's current cookies are captured from CookieManager
**And** cookies are persisted to secure storage by siteId

#### Scenario: Capture cookies before a webspace switch unload

**Given** Site A was activated, and the user then signed in on it
**When** the user switches to a webspace without A, which unloads it
**And** then activates another site
**Then** A's sign-in cookies are in secure storage under A's siteId

### Requirement: ISO-003 - Cookie Restoration on Load

The system SHALL restore site-specific cookies when activating a site via
a capture → nuke → restore cycle:

1. **Snapshot** — call `CookieManager.getAllCookies()` (NOT URL-scoped, so
   sibling-subdomain cookies like `accounts.google.com` are included even
   when the loaded site is `mail.google.com`).
2. **Attribute** — for every loaded non-incognito site (including the
   target if it is already loaded), filter the snapshot by base-domain
   match (`cookie.domain` equals or is a subdomain of the site's base
   domain) and save to that site's siteId-keyed encrypted storage. A loaded
   incognito site's share is held in memory only (INC-001).
3. **Nuke** — `CookieManager.deleteAllCookies()` to evict cookies from
   previously-deleted sites, legacy pre-siteId sessions, and sibling
   subdomains that would otherwise leak into the target's requests.
4. **Restore** — load the target's cookies from storage and set them, then
   restore every other still-loaded site's cookies (parallel-loaded sites
   share the same native jar), an incognito one's from memory.

All async steps before the nuke SHALL check `SiteRuntime.activationVersion`
against the version the activation began at, never one read later, and
early-return if a newer `activate` invocation has bumped it (a row
move bumps nothing: every flow holds its sites, not rows); once
nuked, the jar SHALL be refilled before returning. The engine SHALL run one
operation on the jar at a time (a restore, an unload's capture, a delete's
cleanup), so no capture reads a jar another operation has emptied and saves
the emptiness as the loaded sites' sessions (BUG-032). The turn is a type
(`JarTurn`) only the engine's `_turn` makes, and every read of the jar the
engine saves and every write it makes takes one, so a path to the jar
outside a turn does not compile. `formal/activation.tla`
checks these steps interleaved with other switches, memory pressure and row
moves (`Inv_NoSessionLoss`, `Inv_NoForeignSession`), and catches the jar
without its turns (`noturns`).

#### Scenario: Restore cookies on activation

**Given** Site B has previously stored cookies
**When** Site B is activated
**Then** the native jar is snapshotted via `getAllCookies`
**And** every loaded non-incognito site's cookies are attributed by
  base-domain match and persisted to encrypted storage
**And** the native CookieManager is fully cleared
**And** Site B's cookies are loaded from secure storage and set
**And** every other still-loaded site's cookies are restored to the jar

#### Scenario: No leak from previously-deleted same-base-domain site

**Given** a site on `mail.google.com` was previously deleted while signed in
  (leaving `accounts.google.com` cookies in the native cookie jar)
**When** the user creates a new site for `play.google.com/console` and
  activates it
**Then** the native CookieManager is nuked during activation
**And** the new site loads with only its own (empty) siteId-keyed cookies
**And** no Google account is auto-logged-in

#### Scenario: Sibling-subdomain cookies preserved for still-loaded site

**Given** Site A (`mail.google.com`) has navigated to `accounts.google.com`,
  which set cookies with `Domain=accounts.google.com`
**And** Site B (`example.com`) is also loaded
**When** the user activates Site B
**Then** the native jar is snapshotted via `getAllCookies` (which returns
  cookies for ALL domains, not just those scoped to a single URL)
**And** all of Site A's cookies — including the `accounts.google.com`-scoped
  ones — are attributed to Site A by base-domain match and saved
**And** after the nuke-and-restore, Site A's full cookie set is back in the
  native jar; no session is lost

#### Scenario: Re-activating an already-loaded site preserves its live session

**Given** Site A is active and logged in, the user goes to the home screen
  (`goHome`) without unloading Site A
**When** the user re-activates Site A
**Then** Site A's current native-jar cookies are captured to its siteId
  storage before the nuke
**And** after the nuke-and-restore, Site A's session is intact

#### Scenario: A site loaded off screen at launch restores its own session

**Given** the last session left Site A's cookies in the native jar, and
  Site B, a notification site on Site A's base domain, has its own stored
  session
**When** the app launches and auto-loads Site B (`preload`)
**Then** Site B's webview is built only after a restore has nuked the jar
  and set Site B's stored session
**And** Site B never runs on, or saves as its own, the cookies Site A left
**And** a preload starts only while no activation is in flight, is
  superseded by any input as an activation is, and skips a site whose base
  domain a loaded site already holds (ISO-001)

#### Scenario: Concurrent activation is serialized

**Given** the user taps Site B, then taps Site C before Site B's activation
  completes
**When** Site C's activation runs
**Then** any in-flight step of Site B's activation before its nuke SHALL
  early-return on the version mismatch
**And** Site C's snapshot SHALL NOT read the jar until Site B's restore has
  refilled it
**And** the cookie jar and encrypted storage SHALL NOT reflect interleaved
  captures from the two activations

### Requirement: ISO-004 - CookieManager Cleanup

The system SHALL clear domain cookies from CookieManager between site switches on the same domain.

#### Scenario: Clean CookieManager on switch

**Given** Site A's cookies are in CookieManager
**When** switching to Site B on same domain
**Then** all cookies for the domain are deleted from CookieManager
**Before** Site B's cookies are restored

### Requirement: ISO-005 - Incognito Exemption

Incognito sites SHALL NOT trigger or be affected by domain conflicts.

Every guard in `CookieIsolationEngine` SHALL read
`WebViewModel.effectiveIncognito`, never the stored `incognito` field.
`effectiveIncognito` is forced true for archive-tier sites, and the engine
is the only writer of `CookieSecureStorage` that runs underneath
`_persistSites`'s `!isArchiveTier` filter — so a raw read put an
archive site's non-Secure cookies into plaintext SharedPreferences
(`cookies_fallback`) keyed by its cleartext `siteId`, breaking ARCH-001
byte-identity the moment an archive was opened. The hazard is called out
verbatim in `cookie_secure_storage.dart`. The engine stays free of Flutter
imports; `effectiveIncognito` is a pure getter on the model.

#### Scenario: Incognito site coexists with regular site

**Given** Site A (regular) is active on `github.com`
**And** Site B (incognito) is on `github.com`
**When** Site B is selected
**Then** Site A remains loaded (no conflict)
**And** both sites can be active simultaneously

#### Scenario: Archive-tier site is treated as incognito by the engine

**Given** an archive-tier site with `incognito == false`
**When** `unloadSiteForDomainSwitch`, `restoreCookiesForSite`, or
`preDeleteCookieCleanup` runs with it in `models`
**Then** it is skipped as an incognito site at every guard
**And** `storage.saveCookiesForSite` is never called with a non-empty list
for its `siteId`

### Requirement: ISO-013 - Base Domain Resolution Never Guesses Low

`getBaseDomain` decides which sites share a cookie container and, through
`getNormalizedDomain`, which navigations count as same-site. Collapsing two
unrelated registrants onto one base domain is therefore a container merge
and a same-site-navigation grant at once, so the resolution SHALL err
towards *more* isolation, never less.

There SHALL be no vendored public suffix list — a PSL file is a committed
derivative (CLAUDE.md) and a build-time fetch is out of scope. Instead:

- The multi-part-TLD table SHALL carry the well-known **private** suffixes
  whose registrant hands subdomains to mutually untrusting third parties:
  `github.io`, `pages.dev`, `workers.dev`, `vercel.app`, `netlify.app`,
  `web.app`, `firebaseapp.com`, `appspot.com`, `azurewebsites.net`,
  `herokuapp.com`, `myshopify.com`, `blogspot.com`, `wordpress.com`.
- When a host's last two labels look like a ccTLD registry suffix the table
  does not list (a two-letter TLD under a generic second level such as
  `co`, `com`, `net`, `org`, `edu`, `gov`, `ac`, `ne`, `or`, `go`), the pair
  SHALL be treated as if it were a public suffix rather than as the
  registrable domain. With no label above it that degrades to host equality.

#### Scenario: Two github.io sites are separate sites

**Given** site A is `https://victim.github.io/` and site B is
`https://attacker.github.io/`
**Then** `getBaseDomain` returns `victim.github.io` and
`attacker.github.io` respectively
**And** the two sites do not conflict, do not share a container, and a
navigation from A to B is cross-domain (so
`NavigationDecisionEngine.decideShouldOverrideUrlLoading` reaches the
gesture check instead of returning `allow`)

#### Scenario: A private suffix still groups its own subdomains

**Given** `https://www.victim.github.io/`
**Then** `getBaseDomain` returns `victim.github.io`

#### Scenario: An unlisted registry suffix isolates per host

**Given** `https://a.com.ke/` and `https://b.com.ke/`, where `com.ke` is not
in the table
**Then** `getBaseDomain` returns `a.com.ke` and `b.com.ke`
**And** `https://www.a.com.ke/` still returns `a.com.ke`

### Requirement: ISO-006 - Per-Site Storage

Cookies SHALL be stored per-site (by unique siteId), not per-domain.

#### Scenario: Multiple sites same domain with different cookies

**Given** Site A (`github.com/personal`) has cookies `[session=abc]`
**And** Site B (`github.com/work`) has cookies `[session=xyz]`
**When** cookies are persisted
**Then** Site A's cookies are stored under Site A's siteId
**And** Site B's cookies are stored under Site B's siteId

### Requirement: ISO-007 - Nested Webview Unchanged

Nested webviews (InAppBrowser for external links) SHALL continue using the singleton CookieManager without isolation.

#### Scenario: Open external link in nested webview

**Given** Site A is active
**When** an external link opens in InAppBrowser
**Then** the nested webview uses shared CookieManager
**And** no cookie capture/restore occurs

### Requirement: ISO-008 - Per-Site URL Blocking

Each site's webview SHALL use its own `initUrl` for domain comparison when deciding whether to allow navigation or open in a nested webview.

#### Scenario: Site-specific domain comparison

**Given** Site A (`github.com`) and Site B (`gitlab.com`) are both loaded in IndexedStack
**When** Site B navigates to `gitlab.com/explore`
**Then** navigation is allowed (same normalized domain)
**And** Site A's domain (`github.com`) is NOT used for comparison

#### Scenario: Cross-domain opens nested webview

**Given** Site A (`github.com`) is active
**When** user clicks a link to `gitlab.com`
**Then** navigation is blocked
**And** `gitlab.com` opens in nested webview with `homeTitle="GitHub"`

#### Scenario: Parallel loaded sites maintain separate domain contexts

**Given** Sites A, B, C are all loaded simultaneously in IndexedStack
**When** each site navigates within its own domain
**Then** all navigations are allowed
**And** no cross-site interference occurs

### Requirement: ISO-009 - Widget Identity Preservation

Each site's webview widget SHALL keep its identity by its site, not its position in the stack, so Flutter never hands one site's webview State to another and a change that shifts a site's row neither rebuilds nor reloads its webview. The key is global (`GlobalObjectKey(site)`): `IndexedStack` wraps each child in an unkeyed `Visibility`, so a local key such as `ValueKey(siteId)` never meets its old element once the rows shift.

#### Scenario: Switching sites preserves widget identity

**Given** Site A and Site B are in IndexedStack
**When** user switches from Site A to Site B and back
**Then** each widget maintains its own state
**And** callbacks reference the correct site's `initUrl`

#### Scenario: Deleting or moving a site keeps the other webviews

**Given** Site A and Site B are both loaded, A in the row before B
**When** A is deleted, or the two swap rows
**Then** B's webview keeps its State: its page is neither rebuilt nor reloaded

### Requirement: ISO-010 - Cookie Cleanup on Site Deletion

The system SHALL clean up all cookie-related data when a site is deleted.

#### Scenario: Delete only site on a domain

**Given** Site A (`linkedin.com`) is the only site on that domain
**When** the user deletes Site A
**Then** all cookies for `linkedin.com` are deleted from the webview cookie jar
**And** Site A's cookies are removed from secure storage (by siteId)
**And** Site A's HTML cache is deleted

#### Scenario: Delete one of multiple sites on same domain

**Given** Site A (`github.com/personal`) and Site B (`github.com/work`) exist
**When** the user deletes Site A
**Then** cookies for Site A's URL(s) are deleted from the native cookie jar
  unconditionally
**And** Site A's cookies are removed from secure storage (by siteId)
**And** Site A's HTML cache is deleted
**And** orphaned per-siteId entries are swept from encrypted storage and
  HTML cache as defense in depth
**And** Site B continues to function with its cookies intact after next
  activation (which triggers restore from its siteId-keyed storage)

#### Scenario: Deleting a site while a same-base-domain site is loaded preserves its live session

**Given** Site A (`github.com/personal`) and Site B (`github.com/work`) exist
**And** Site B is currently active/loaded with a live session in the native
  cookie jar
**When** the user deletes Site A
**Then** before the URL-scoped delete, the system snapshots all native
  cookies matching the deleted base domain via `getAllCookies()`
**And** after the URL-scoped delete (which would otherwise wipe Site B's
  session because `github.com/personal` and `github.com/work` share a
  host), Site B's snapshot is restored to the native jar
**And** Site B's live session is NOT interrupted — no reload or re-login
  is required

#### Scenario: Re-adding a deleted site starts fresh

**Given** Site A (`linkedin.com`) was the only site on that domain and was deleted
**When** the user adds a new site for `linkedin.com`
**Then** the new site has no pre-existing cookies
**And** the user must log in again

### Requirement: ISO-011 - Per-Site Cookie Blocking

The system SHALL allow blocking specific cookies by name + domain on a per-site basis. Blocked cookies are deleted from the webview cookie jar after each page load and skipped during cookie restoration.

> **Profile mode note.** This requirement applies in legacy mode
> (`_useProfiles == false`); the delete routes through the global
> `CookieManager`. In profile mode the same scenarios are satisfied
> by [CONT-006 — Cookie Ops via ContainerCookieManager](../per-site-containers/spec.md#requirement-cont-006--cookie-ops-via-containercookiemanager),
> which does the delete via the patched `inapp.CookieManager`'s
> `webViewController:` parameter so the per-site profile's cookie
> store is targeted (HttpOnly cookies included).

#### Scenario: Block a cookie from the cookie inspector

**Given** Site A has cookies including `_ga` on `.google.com`
**When** the user opens Developer Tools -> Cookies tab and taps "Block" on `_ga`
**Then** a `BlockedCookie(name: "_ga", domain: ".google.com")` is added to Site A's `blockedCookies` set
**And** the cookie is immediately deleted from the webview
**And** the block rule is persisted via site serialization

#### Scenario: Blocked cookie re-set by website is removed

**Given** Site A has `_ga` on `.google.com` blocked
**When** a page load completes and the website sets `_ga` again
**Then** `onCookiesChanged` filters out `_ga` and deletes it from CookieManager
**And** the cookie does not appear in `model.cookies`

#### Scenario: Blocked cookie skipped during restore

**Given** Site A has `_ga` blocked and stored cookies include `_ga`
**When** Site A is activated and `_restoreCookiesForSite()` runs
**Then** `_ga` is NOT set in CookieManager
**And** other non-blocked cookies are restored normally

#### Scenario: Unblock a cookie

**Given** Site A has `_ga` blocked
**When** the user opens the Blocked section in the Cookies tab and taps "Unblock"
**Then** the `BlockedCookie` is removed from `blockedCookies`
**And** the cookie can be set again on next page load

#### Scenario: Legacy data without blockedCookies

**Given** a site was serialized before the cookie blocking feature existed
**When** the site is deserialized
**Then** `blockedCookies` defaults to an empty set
**And** no cookies are blocked

### Requirement: ISO-012 - Native Cookie Jar Garbage Collection

The system SHALL garbage-collect the native cookie jar (iOS `WKHTTPCookieStorage`, Android `CookieManager`) at every boundary where cookies from deleted sites, sibling subdomains, or legacy pre-siteId sessions could leak into unrelated sites. The native jar is a process-wide shared store that persists across app launches and is not keyed by siteId, so without an explicit GC step, accumulated cookies cross-pollinate across the app's per-site model.

The boundaries:

- **On app startup** — in the jar's first turn: queued as soon as the
  engine is chosen, before the site list can be tapped, and run only while
  no site is loaded (`CookieIsolationEngine.clearUnloaded`). Queued later,
  as the post-paint sweep once did it outside the jar's turns, it empties
  the sessions the launch's restores put back
- **On site switch** — inside `_restoreCookiesForSite`, after capturing
  cookies for other loaded sites
- **On settings import** — `activate` during import routes through
  `_restoreCookiesForSite`, which performs the nuke-and-restore cycle; the
  import path MUST NOT issue a subsequent `deleteAllCookies()` or it would
  wipe the session just restored for the imported active site. An import
  that activates nothing empties the jar through `clearUnloaded`, in the
  jar's turn and only while no site is loaded
- **On site deletion** — for the deleted site's `initUrl` and `currentUrl`
  unconditionally, followed by an orphan sweep of siteId-keyed storage; if
  a loaded same-base-domain site exists, its session SHALL be snapshotted
  via `getAllCookies()` before the delete and restored after

#### Scenario: Startup evicts cookies from deleted-in-previous-session sites

**Given** in a previous session the user had Site A (`mail.google.com`)
  signed in, then deleted it
**And** `WKHTTPCookieStorage` still contains `.google.com` and
  `accounts.google.com` cookies from that session
**When** the app launches
**Then** orphaned siteId-keyed entries are swept from encrypted storage and
  HTML cache
**And** the native cookie jar is cleared in the jar's first turn, before any
  site's restore
**And** the first activated site restores only its own siteId-keyed cookies

#### Scenario: The launch clear never empties a restored session

**Given** a notification site was preloaded, or the user tapped a site,
  while the launch was still under way
**When** its restore has refilled the jar
**Then** no jar clear runs after it at that launch
**And** the post-paint orphan sweep issues no `deleteAllCookies()` at all
  (`formal/activation.tla`, the cold start's `lateclear` mistake)

#### Scenario: Orphan sweep runs on site deletion

**Given** the user deletes a site
**When** the delete flow completes
**Then** `OrphanSweepEngine` runs every store against the updated site set
  (the non-incognito one for session stores such as cookies and HTML cache,
  per incognito-mode INC-006)
**And** the shared cookie jar is not cleared
**And** any encrypted-storage or HTML-cache entries not referenced by a
  surviving site are removed

### Requirement: ISO-014 - A Jar That Fails Is Never Read as Empty

Every call on the plugin's cookie channel SHALL go through `cookieChannel`
([cookie_manager.dart](../../../lib/services/cookie_manager.dart)), which
names what the channel fails with once: an error envelope from the native
side (`PlatformException`) and a channel with no handler in this engine
(`MissingPluginException`) reach a caller only as `CookieJarFailure`.

A read that failed SHALL NOT be taken for an empty jar: nothing is saved from
it over a stored session, and the jar is not emptied after it. A write that
failed SHALL NOT be reported as done. Each caller answers the failure in its
own terms:

- An unload's capture (ISO-002) keeps the set the site last saved, and the
  unload goes on.
- An activation's restore (ISO-003) fails. A failed read saves nothing and
  empties nothing; a refused write leaves the rest of the refill to run
  first. The activation does not show its target, since until the jar is
  emptied and refilled it can hold another same-base-domain site's session
  (ISO-001): the webspace list is shown, with a message naming the site.

Each of these refusals is the step's own outcome (`Refused`), which
`formal/activation.tla` takes in a world whose jar may refuse any read, nuke
or write (`JarRefuses`): there no site is shown or loaded on another site's
session, whatever lands meanwhile.
- A deletion's jar cleanup (ISO-010) drops the deleted site's stored cookies
  first; a jar that fails is left for the next activation to empty
  (ISO-012), and the deletion goes on.
- The jar clear at launch, and after an import that restores no site
  (ISO-012), is left to the next activation; the sweep and the import go on.
- The cookie mirror after a page load keeps the site's last saved cookies,
  and the rest of the load's work runs.
- A blocked cookie the jar refuses to delete stays for the next load to take
  (ISO-011), and the others go.
- Clear Cookies on a site's settings reports the failure instead of
  "Cookies cleared", and the site keeps its list.

What the channel reports is what this covers: Linux's native side answers a
failed `getCookies` with an empty list (it logs the `GError` and replies
success), so there a failed read still arrives as an empty jar.

#### Scenario: A capture on unload that cannot read the jar

**Given** Site A is loaded and its signed-in cookies are in secure storage
**When** A is unloaded and the jar cannot be read
**Then** A is unloaded
**And** A's stored cookies are unchanged

#### Scenario: An activation whose restore cannot read the jar

**Given** Site A is loaded and signed in, and Site B is not loaded
**When** the user opens B and the jar cannot be read
**Then** nothing is saved over A's stored cookies and the jar is not emptied
**And** B is not shown or loaded; the webspace list is shown with a message
  that B could not be opened

#### Scenario: A refill that refuses one cookie

**Given** the restore has emptied the jar
**When** the jar refuses one of the cookies written back
**Then** every other stored cookie is still written
**And** the restore fails, so the activation does not show its target

#### Scenario: A deletion whose jar cleanup fails

**Given** Site A and Site B share a base domain and B is loaded with a live
  session
**When** the user deletes A and the jar cannot be read
**Then** A's stored cookies are removed
**And** B's live session is still in the jar

#### Scenario: A launch jar clear the jar refuses

**Given** the legacy engine runs the launch sweep
**When** the jar refuses the clear
**Then** the sweep goes on, and the next activation empties the jar before
  any site shows

#### Scenario: A clear the jar refuses

**Given** the user taps Clear Cookies on a site's settings and confirms
**When** the jar refuses a delete
**Then** the screen says the cookie store failed, not "Cookies cleared"

## Implementation Details

### Logic Engines

Orchestration lives in pure-Dart engines under `lib/services/*_engine.dart`
so the flows can be exercised headlessly with in-memory fakes of
`CookieManager` / `CookieSecureStorage` instead of a widget tree. Same
code runs in production; the split is strictly between logic and the
rendering side (native cookie jar, webview lifecycle, `setState`) which
stays at the `_WebSpacePageState` call site.

- [`CookieIsolationEngine`](../../../lib/services/cookie_isolation.dart) —
  owns the capture-nuke-restore cycle for `unloadSiteForDomainSwitch`,
  `restoreCookiesForSite`, and `preDeleteCookieCleanup`. Tests model RFC
  6265 domain-match semantics in `MockCookieManager`
  ([test/cookie_isolation_integration_test.dart](../../../test/cookie_isolation_integration_test.dart)).
- [`SiteUnloadEngine.conflicts`](../../../lib/services/site_unload_engine.dart) —
  the model's `Conflicts(s)`, a definition deciding which loaded sites
  must unload before activating the target per ISO-001; the residency
  plan runs it, the preload's guard and the ISO-001 assert call it, and
  `formal/verify.sh` prints it, so the rule can't
  diverge between prod and tests.
- [`SiteRuntime`](../../../lib/controllers/site_runtime.dart) holds the
  loaded sites and the one on screen as sites, so a deletion (ISO-010)
  takes the deleted site out of both and leaves every other one naming
  the site it did; webspaces hold site ids and are re-resolved after it.

### Domain Comparison for Cookie Isolation

Uses `getBaseDomain()` for conflict detection:
- `api.github.com` -> `github.com`
- `gist.github.com` -> `github.com`
- Sites sharing second-level domain are considered conflicting

**Multi-part TLD Support:**
Handles country-code second-level domains like `.co.uk`, `.com.au`:
- `www.google.co.uk` -> `google.co.uk`
- `bbc.co.uk` -> `bbc.co.uk`
- `amazon.co.jp` -> `amazon.co.jp`

Defined in `_multiPartTlds` set covering 50+ common patterns.

**IP Address Support:**
IP addresses (IPv4 and IPv6) are returned as-is since they're already unique identifiers:
- `http://192.168.1.1:8080` -> `192.168.1.1`
- `http://10.0.0.1:3000/app` -> `10.0.0.1`
- `http://[::1]:8080` -> `::1`

Two sites on the same IP address will conflict (same as domains).

### Domain Aliases for Navigation (Separate from Cookie Isolation)

Uses `getNormalizedDomain()` for nested webview URL blocking only:
- `gmail.com` -> `google.com` (alias)
- `google.co.uk` -> `google.com` (regional alias)
- `claude.ai` -> `anthropic.com` (alias)
- `chatgpt.com` -> `openai.com` (alias)

**Important:** Domain aliases affect ONLY nested webview navigation, NOT cookie isolation. Two sites on `gmail.com` and `google.com` have separate cookie stores (different second-level domains).

### Per-Site Cookie Blocking

Each `WebViewModel` has a `Set<BlockedCookie> blockedCookies` field. A `BlockedCookie` is a pair of `(name, domain)` with value-based equality.

**Enforcement points:**
1. `onCookiesChanged` callback: after fetching cookies from the webview on page load, blocked cookies are filtered out and deleted from CookieManager
2. `_restoreCookiesForSite()`: blocked cookies are skipped when restoring cookies to CookieManager
3. Serialization: `blockedCookies` is included in `toJson()` / `fromJson()` (omitted when empty for backward compatibility)

**Domain matching:** Supports exact match and subdomain matching. A rule for `example.com` also blocks cookies from `sub.example.com`.

**UI:** The cookie inspector in DevTools shows a "Block" button on each cookie and a "Blocked" section listing blocked rules with "Unblock" buttons.

### Site ID Generation

Each WebViewModel has a unique `siteId` field:
- Format: `{timestamp_base36}-{random_base36}` (e.g., `lqv2x3k-abc123`)
- Auto-generated on creation using `DateTime.now().microsecondsSinceEpoch`
- Preserved through serialization (JSON)
- Used as storage key for cookies

### Cookie Storage

Cookies stored in `CookieSecureStorage` keyed by siteId:
- Legacy domain-keyed data is migrated on first access
- Each site maintains its own isolated cookie store
- Empty cookie lists remove the siteId key (cleanup)

### Aggressive Cookie Clearing

The native cookie jar is nuked on EVERY site activation (not just same-domain
switches). The capture uses `CookieManager.getAllCookies()` rather than
URL-scoped `getCookies(url)` because sibling-subdomain cookies (e.g.
`accounts.google.com` when the site is `mail.google.com`) are NOT returned
by a URL-scoped query and would otherwise be lost across the nuke.

Attribution to a site is by base-domain match: a cookie with `domain`
equal to the site's base domain, or ending with `.<baseDomain>`, is
attributed to that site. Per-site cookie isolation (ISO-001) guarantees
at most one loaded site per base domain, so attribution is unambiguous.

The sequence in `_restoreCookiesForSite`:
1. `getAllCookies()`
2. For each loaded non-incognito site (including target if already
   loaded): filter by base-domain, save to siteId storage.
3. `deleteAllCookies()`
4. Restore target's cookies from storage.
5. Restore every other still-loaded site's cookies.

Also runs at startup (before first activation). Settings import routes
activation through the same path and MUST NOT nuke afterwards.

### Orphan GC

Per-siteId encrypted storage and HTML cache accumulate entries for deleted
sites. `OrphanSweepEngine` sweeps every per-site store, including
`CookieSecureStorage` and `HtmlCacheService`, for entries whose siteId is
not live. It runs:
- After the first paint of a launch (`sweepOrphanStorage`), followed by the
  legacy global jar clear
- On site deletion (in `SiteEditingController.deleteSite`)
- On settings import (in backup restore)

The native cookie jar is GC'd by `deleteAllCookies()` at the same boundaries
(see Aggressive Cookie Clearing above).

### UI Updates on Navigation

`WebViewModel.onUrlChanged` triggers `stateSetterF()` to update:
- URL bar display
- Page title extraction
- State persistence

### Nested Webview URL Blocking (shouldOverrideUrlLoading)

Each site's webview has a `shouldOverrideUrlLoading` callback that:
1. Compares the request URL's normalized domain with the site's `initUrl` normalized domain
2. If same domain: allows navigation (returns `true`)
3. If different domain: blocks navigation, opens URL in nested InAppBrowser with site's name as `homeTitle`

```dart
shouldOverrideUrlLoading: (url, shouldAllow) {
  final requestNormalized = getNormalizedDomain(url);
  final initialNormalized = getNormalizedDomain(initUrl);  // Captured from closure

  if (requestNormalized == initialNormalized) {
    return true;  // Allow - same logical domain
  }

  launchUrlFunc(url, homeTitle: name);  // Open nested webview
  return false;  // Cancel navigation
}
```

**Critical**: The callback captures `initUrl` from the WebViewModel instance's closure. Each site must have its own callback instance to prevent cross-site interference.

### Widget Identity with ValueKey

IndexedStack keeps all child widgets in the tree. To ensure Flutter doesn't incorrectly reuse widget state when switching sites:

```dart
IndexedStack(
  index: currentIndex,
  children: [
    for (final model in webViewModels)
      Column(
        key: ValueKey(model.siteId),  // Ensures widget identity
        children: [model.getWebView(...)],
      ),
  ],
)
```

## Files

### Modified
- `lib/web_view_model.dart` - siteId, domain functions, captureCookies(), disposeWebView()
- `lib/main.dart` - Domain conflict detection, async activate(), _unloadSite()
- `lib/services/webview.dart` - deleteAllCookies() method on CookieManager
- `lib/services/cookie_secure_storage.dart` - loadCookiesForSite(), saveCookiesForSite(), removeOrphanedCookies()

### Created
- `lib/services/cookie_isolation.dart` - `CookieIsolationEngine` (capture-nuke-restore)
- `test/cookie_isolation_test.dart` - Unit tests for domain extraction, aliases, siteId
- `test/cookie_isolation_integration_test.dart` - Integration tests with mock CookieManager
- `test/site_unload_engine_test.dart` - Unit tests for domain-conflict resolution (`SiteUnloadEngine.conflicts`)
- `test/nested_webview_navigation_test.dart` - Tests for per-site URL blocking and widget identity
- `openspec/specs/per-site-cookie-isolation/spec.md` - This specification

## Migration

For existing users upgrading:
1. On first load, cookies are migrated from domain-keyed to siteId-keyed
2. First site for each domain receives the domain's cookies
3. Additional sites on same domain start fresh
4. Users can log in to each site; cookies are captured per-site going forward

## Testing

### Unit Tests

```bash
# Run cookie isolation unit tests (domain extraction, siteId, aliases)
flutter test test/cookie_isolation_test.dart

# Run cookie secure storage tests (siteId-based storage)
flutter test test/cookie_secure_storage_test.dart

# Run web view model tests (serialization with siteId)
flutter test test/web_view_model_test.dart
```

### Integration Tests

```bash
# Run cookie isolation integration tests (mock CookieManager scenarios)
flutter test test/cookie_isolation_integration_test.dart
```

Integration tests cover:
- 3 sites scenario (2 same domain, 1 different)
- Different domains don't conflict
- Subdomains of same second-level domain conflict
- Incognito sites don't participate in conflicts
- Cookie persistence across domain switches
- New site on same domain starts clean
- Third-party domain always accessible alongside same-domain conflicts

### Nested Webview Navigation Tests

```bash
# Run nested webview navigation tests (per-site URL blocking)
flutter test test/nested_webview_navigation_test.dart
```

Navigation tests cover:
- Each site uses its own `initUrl` for domain comparison
- Parallel loaded sites don't interfere with each other
- Rapid switching between sites maintains correct domain checks
- Domain aliases work correctly per site (gmail.com -> google.com)
- Cross-domain navigation opens nested webview with correct `homeTitle`
- Widget identity preserved via `ValueKey(siteId)` in IndexedStack

### Run All Tests

```bash
flutter test
```

## Manual Testing

1. Create two sites on same domain (e.g., `github.com/personal`, `github.com/work`)
2. Log into first site, verify session established
3. Switch to second site, verify first site's webview is disposed
4. Log into second site with different account
5. Switch back to first site, verify original session is restored
6. Create incognito site on same domain, verify no conflict occurs

### Multi-part TLD Testing

1. Create site on `google.co.uk`
2. Verify it extracts to `google.co.uk` (not `co.uk`)
3. Create second site on `mail.google.co.uk`
4. Verify they conflict (same second-level domain)

### Domain Alias Testing

1. Create site on `gmail.com`
2. Navigate to a Google sign-in page
3. Verify navigation stays in same webview (gmail.com aliased to google.com for navigation)

### Nested Webview Navigation Testing

1. Create Site A (`github.com`) and Site B (`gitlab.com`)
2. Click Site A, then click Site B
3. On Site B, click a link to `gitlab.com/explore`
4. Verify navigation stays in Site B's webview (NOT opened as nested)
5. On Site B, click a link to `github.com`
6. Verify link opens in nested webview with "GitLab" as home title
7. Switch back to Site A, click a link to `gitlab.com`
8. Verify link opens in nested webview with "GitHub" as home title

### Parallel Site Navigation Testing

1. Create 3 sites on different domains (e.g., GitHub, GitLab, Bitbucket)
2. Visit each site to ensure all 3 are loaded in IndexedStack
3. On each site, navigate within its own domain
4. Verify all navigations stay in their respective webviews
5. Verify no site uses another site's domain for URL blocking
