## ADDED Requirements

### Requirement: LIR-001 - Per-Site Domain Claim List

Each site SHALL carry a list of domain claims that declare which URLs it handles. A claim has a `kind` of `exactHost`, `wildcardSubdomain`, or `baseDomain`, and a canonical lowercase `value` with no scheme or port. Existing sites SHALL auto-synthesize one `baseDomain` claim equal to `getBaseDomain(initUrl)` on first load after upgrade. The `domainClaims` list SHALL persist as part of `WebViewModel` JSON, and SHALL be omitted from serialization output when it equals the synthesized legacy default.

#### Scenario: Legacy site migrates with synthesized claim

- **WHEN** a `WebViewModel` is deserialized from JSON that does not contain `domainClaims`
- **THEN** the site's in-memory `domainClaims` is `[DomainClaim(baseDomain, getBaseDomain(initUrl))]`
- **AND** subsequent serialization omits `domainClaims` when it equals the synthesized default

#### Scenario: User defines multiple claims on one site

- **WHEN** the user saves claims `[exactHost:google.com, wildcardSubdomain:google.com, exactHost:gmail.com]` on a Google site
- **THEN** the site stores all three claims verbatim
- **AND** `google.com`, `mail.google.com`, and `gmail.com` all route to that site via the resolver

#### Scenario: User-defined claims persist across restart

- **GIVEN** the user saved claims `[exactHost:google.com, wildcardSubdomain:google.com]` on a site
- **WHEN** the app is restarted
- **THEN** the site's `domainClaims` list loads exactly as saved

---

### Requirement: LIR-002 - URL Routing Resolver

The system SHALL resolve an incoming `http`/`https` URL to exactly one site (or "no match") using a deterministic specificity ranking: `exactHost` (score 300) > `wildcardSubdomain` (score 200) > `baseDomain` (score 100). On a score tie, the system SHALL surface a disambiguation picker. On no match, the system SHALL surface a "Create site for <host>?" bottom sheet.

#### Scenario: Exact host beats wildcard

- **WHEN** site A claims `wildcardSubdomain:mastodon.social` and site B claims `exactHost:mastodon.social`
- **AND** the incoming URL is `https://mastodon.social/@user`
- **THEN** the resolver returns site B

#### Scenario: Wildcard matches subdomain but not base

- **WHEN** site A claims `wildcardSubdomain:mastodon.social` only
- **AND** the incoming URL is `https://mastodon.social/`
- **THEN** site A's wildcard claim does not match
- **AND** any `baseDomain` or `exactHost` claim on other sites is consulted instead

#### Scenario: Tie surfaces picker

- **WHEN** two sites both claim `exactHost:reddit.com`
- **AND** the incoming URL is `https://reddit.com/r/flutter`
- **THEN** a disambiguation picker is shown listing both sites
- **AND** the chosen site receives the full URL

#### Scenario: No match offers create

- **WHEN** no site's claims match the incoming URL
- **THEN** the app shows a "Create site for <host>?" bottom sheet
- **AND** accepting creates a site with `initUrl` set to the incoming URL and a synthesized `baseDomain` claim

---

### Requirement: LIR-003 - Claim Conflict Validation

The system SHALL prevent a site from claiming a domain whose base domain equals another site's `initUrl` base domain. The system SHALL warn (non-blocking) on overlapping claims that are not outright hijacks.

#### Scenario: Hijack attempt blocked

- **GIVEN** site A's `initUrl` is `https://github.com/alice`
- **WHEN** the user tries to save `exactHost:github.com` on site B
- **THEN** the editor shows a validation error referencing site A
- **AND** the claim is not saved

#### Scenario: Overlapping non-hijack warns

- **GIVEN** site A claims `wildcardSubdomain:example.com`
- **WHEN** the user saves `exactHost:blog.example.com` on site B
- **THEN** the editor shows a non-blocking warning
- **AND** the claim is saved
- **AND** the resolver picks site B for `https://blog.example.com/` (higher specificity)

---

### Requirement: LIR-004 - `webspace://` URL Scheme

The app SHALL register the `webspace` URL scheme on every supported platform (Android intent-filter, iOS/macOS `CFBundleURLTypes`, Linux `.desktop` `MimeType=x-scheme-handler/webspace;`). The canonical form is `webspace://open?url=<percent-encoded-target>` where the target SHALL be a `http` or `https` URL. Invalid targets SHALL be ignored silently with a snackbar; the app SHALL NOT crash on malformed input.

#### Scenario: External app opens `webspace://` URL

- **GIVEN** another app provides a button that calls `Intent.ACTION_VIEW` (Android) / `UIApplication.open` (iOS) / `xdg-open` (Linux) on `webspace://open?url=https%3A%2F%2Ftwitter.com%2Fuser`
- **WHEN** the OS dispatches the URL
- **THEN** WebSpace launches (or is brought to foreground) without a chooser, since no other app handles `webspace://`
- **AND** the resolver receives `https://twitter.com/user`
- **AND** the matching site (or no-match flow) handles it

#### Scenario: Invalid target URL

- **WHEN** the app receives `webspace://open?url=javascript%3Aalert(1)` or any non-http(s) target
- **THEN** the URL is dropped
- **AND** a snackbar reports "Unsupported URL scheme"
- **AND** the app does not crash

#### Scenario: Cold start via `webspace://` URL

- **GIVEN** WebSpace is not running
- **WHEN** the OS launches it with a `webspace://open?url=...` URL
- **THEN** the main app calls `LinkIntentService.getInitialUrl()` after `runApp()`
- **AND** the URL is delivered exactly once
- **AND** subsequent calls to `getInitialUrl()` return null

#### Scenario: Warm start via `webspace://` URL

- **GIVEN** WebSpace is already running in the background
- **WHEN** the OS dispatches a `webspace://open?url=...` URL
- **THEN** `LinkIntentService` emits the URL on its `Stream<Uri>`
- **AND** `WebSpacePage` runs the resolver and activates the matching site

---

### Requirement: LIR-005 - Android Share Intent Handler

The Android app SHALL declare an `ACTION_SEND` intent-filter with `mimeType="text/plain"` on `MainActivity`. Shared text that contains an `http://` or `https://` URL (after trimming) SHALL be delivered to the resolver. The intent activity SHALL NOT request `FLAG_ACTIVITY_NEW_TASK` so that pressing Back returns to the referring app.

#### Scenario: Share a URL from another app

- **GIVEN** the user is in Chrome on an article page
- **WHEN** the user taps "Share" and selects WebSpace
- **THEN** WebSpace launches
- **AND** the article URL is passed to the resolver
- **AND** the matching site's webview navigates to the article URL

#### Scenario: Share non-URL text

- **WHEN** the user shares plain text without a URL to WebSpace
- **THEN** the app launches to its previous state without routing
- **AND** a snackbar informs the user that no URL was found

#### Scenario: Back returns to referrer

- **GIVEN** the user shared a URL from Gmail to WebSpace
- **WHEN** the matching site is loaded and the user presses the system Back button
- **THEN** Gmail returns to the foreground
- **AND** WebSpace is not relaunched into its home state

---

### Requirement: LIR-006 - iOS Share Extension

The iOS app SHALL ship a Share Extension target that accepts Web URLs (`NSExtensionActivationSupportsWebURLWithMaxCount = 1`) and HTML files (`NSExtensionActivationSupportsFileWithMaxCount`, handled per LIR-012). The extension SHALL hand the URL to the main app via `extensionContext.open(URL(string: "webspace://open?url=<encoded>")!)` and then call `completeRequest(returningItems: nil)`. The main app SHALL handle the resulting `webspace://open` URL via LIR-004.

#### Scenario: Share from Safari

- **GIVEN** the user is on an article in Safari
- **WHEN** the user taps the share button and selects WebSpace
- **THEN** the Share Extension launches briefly
- **AND** the main app opens with the article URL routed to the matching site
- **AND** the OS shows a "← Safari" breadcrumb in the status bar that returns the user on tap

#### Scenario: Share Extension with no URL

- **WHEN** the share sheet contains only text without a URL
- **THEN** WebSpace does not appear in the share sheet (filtered by `NSExtensionActivationRule`)

---

### Requirement: LIR-007 - macOS Share Extension

The macOS app SHALL ship a Share Extension target with behavior equivalent to iOS (LIR-006). Data transfer to the main app uses the same `webspace://open?url=...` scheme.

#### Scenario: Share from Safari on macOS

- **WHEN** the user shares a URL from Safari to WebSpace
- **THEN** the main app opens with the URL routed to the matching site
- **AND** the OS shows a back-to-Safari affordance in the menu bar

---

### Requirement: LIR-008 - Link Handling Settings Screen

The app SHALL provide a "Link handling" screen inside Settings containing a master "Handle shared links" switch, a "Claim domains from shared links" switch (the opt-in for LIR-010 option 2 binding; default off; disabled while the master switch is off), and a "Routing overview" list showing every domain pattern → owning site with conflict warnings.

#### Scenario: Master switch disabled

- **WHEN** the user turns off the master switch
- **THEN** `LinkIntentService` ignores subsequent URLs from any source (Android `ACTION_SEND`, `webspace://`, iOS/macOS Share Extension) and logs them
- **AND** the iOS/macOS Share Extension reads the flag from the App Group and shows "WebSpace link handling is disabled" instead of opening the main app

#### Scenario: Routing overview reflects claims

- **GIVEN** site A claims `exactHost:twitter.com`, `exactHost:x.com`
- **WHEN** the user opens the Routing overview
- **THEN** both patterns are listed with site A as the owner

#### Scenario: Tap row opens site editor

- **WHEN** the user taps a row in the Routing overview
- **THEN** the owning site's editor opens scrolled to the domain-claim list

---

### Requirement: LIR-011 - Engine-Driven Dispatch: Cross-Domain Goes Nested; In-Domain Resets Incognito / Always-Home

The dispatch decision tree for an inbound shared URL targeting an existing site SHALL live in a pure-Dart engine, `LinkIntentDispatchEngine` (mirroring the engine pattern in `cookie_isolation.dart` / `site_activation_engine.dart`). The engine takes the inbound payload and a list of `DispatchableSite` adapters and returns a `DispatchAction`. The view layer SHALL be a thin executor that performs IO/UI for the returned action; it MUST NOT recompute routing decisions of its own. This keeps every reset/disposal/wipe path testable with fakes.

The engine SHALL emit:

1. **Out-of-domain share** — when `getNormalizedDomain(url) != site.navigationDomain` (e.g. user routes `f-droid.org` to a `duckduckgo.com` site after binding it), `DispatchOpenNested(siteId, url)`. The executor SHALL invoke the existing nested in-app-webview path (`launchUrl(...)`) carrying the chosen site's privacy settings (siteId/container, incognito, proxy, language, location, WebRTC, user scripts, blocking toggles, notifications). The site's main webview SHALL NOT be navigated. This both matches user expectation ("a shared link from another app shouldn't trample my session") and avoids being silently blocked by the in-webview cross-domain navigation guard.
2. **In-domain share, target site has `incognito` or `alwaysOpenHome` set** — `DispatchOpenInMain(siteId, url, disposeBeforeLoad: true, wipeContainer: incognito, clearInMemoryCookies: incognito)`. The executor SHALL dispose the live webview, drop it from `_loadedIndices`, evict its in-memory HTML cache (online only), reset `currentUrl = initUrl`, wipe the container if `wipeContainer == true`, and clear in-memory cookies if `clearInMemoryCookies == true` — all BEFORE activating and calling `controller.loadUrl(url)`. The flags being engine-emitted (rather than computed at the call site) is the IP-leakage / session-leakage defence: a future caller cannot accidentally skip the disposal.
3. **In-domain share, regular site** — `DispatchOpenInMain(siteId, url, disposeBeforeLoad: false, wipeContainer: false, clearInMemoryCookies: false)`. The executor activates and `controller.loadUrl(url)` (existing behaviour).

The engine SHALL also expose follow-up entry points for the LIR-010 picker: `openInChosen(inbound, site)`, `bindToSite(inbound, site)` (returns `DispatchBindAndOpen` with `claimAdditions` + an engine-computed `followUp`), and `createNew(inbound)` (returns `DispatchCreateSite` for option 3 or `DispatchUnsupported` if the URL has no host).

#### Scenario: Cross-domain bind opens nested

- **GIVEN** the user has a `duckduckgo.com` site (incognito off) and no `f-droid.org` site
- **WHEN** they share `https://f-droid.org/packages/<pkg>` and pick "Send f-droid.org to my DuckDuckGo site"
- **THEN** the DuckDuckGo site's claim list gains `[exactHost(f-droid.org), wildcardSubdomain(f-droid.org)]`
- **AND** the f-droid URL opens in a nested `InAppWebViewScreen` carrying DuckDuckGo's privacy/container settings
- **AND** the DuckDuckGo main webview's URL does NOT change

#### Scenario: In-domain share to incognito site resets the session

- **GIVEN** an incognito `example.org` site has accumulated cookies and is mid-session on `https://example.org/account`
- **WHEN** the user shares `https://example.org/articles/foo` and dispatches it to that site
- **THEN** the live webview is disposed
- **AND** the site's container is wiped
- **AND** in-memory cookies are cleared
- **AND** `currentUrl = initUrl` before the activation
- **AND** the shared URL loads in a fresh main webview

#### Scenario: In-domain share to always-home site discards mid-session URL

- **GIVEN** an `example.org` site with `alwaysOpenHome=true` is mid-session on `https://example.org/page42`
- **WHEN** the user shares `https://example.org/another` and dispatches it to that site
- **THEN** the live webview is disposed and `currentUrl` is reset to `initUrl`
- **AND** the shared URL then loads — cookies are NOT cleared (always-home preserves login state per its existing semantics)

#### Scenario: In-domain share to regular site uses normal navigation

- **GIVEN** a non-incognito, non-always-home `example.org` site mid-session
- **WHEN** the user shares an in-domain URL to it
- **THEN** the engine emits `DispatchOpenInMain` with all reset flags `false`
- **AND** the executor uses the existing webview's `controller.loadUrl(url)`
- **AND** no dispose / wipe / cookie clear is performed

#### Scenario: Engine owns the in-domain decision; view executes only

- **WHEN** any caller dispatches an inbound URL
- **THEN** all "main vs nested" and "reset vs in-place" decisions are made inside `LinkIntentDispatchEngine`
- **AND** the executor in `_WebSpacePageState` performs the IO described by the returned `DispatchAction` without re-evaluating domain/reset rules

---

### Requirement: LIR-012 - HTML File Share Goes Only To Create-New-Site

When the OS hands the app an HTML file via share (Android `ACTION_SEND` carrying `EXTRA_STREAM`; iOS Share Extension via an app-group handoff), the dispatcher SHALL skip the LIR-010 picker entirely and emit `DispatchCreateSiteFromHtml(html, suggestedTitle)`. On iOS the Share Extension SHALL declare `NSExtensionActivationSupportsFileWithMaxCount` so HTML files surface the extension, read the shared document (from a `public.html` attachment, a `Data` attachment, or a file URL ending in `.html`/`.htm`/`.xhtml`), write the document into the shared app-group container (a URL scheme cannot carry a whole document), and wake the app with a bare `webspace://openhtml` trigger; the main app SHALL drain that container on its next share poll (`consumeLaunchHtml`), returning the content, `<title>`-or-filename title, and source filename, then delete the container copy so the same file is not imported twice. The Android intent handler SHALL NOT rely solely on the intent's declared MIME type or the stream URI's path to recognise HTML, because file managers frequently share `.html` files as `text/plain` or `application/octet-stream` and `content://` URIs carry no filename in their path. It SHALL treat an `EXTRA_STREAM` payload as HTML when any of the following hold: the intent MIME is `text/html`/`application/xhtml+xml`; the `ContentResolver`-resolved type is `text/html`/`application/xhtml+xml`; the resolver-provided display name (or, absent that, the URI path) ends in `.html`/`.htm`/`.xhtml`; or the leading bytes sniff as HTML (`<!doctype html`, `<html`, `<head`, or `<body`). The suggested title SHALL derive from the document `<title>` first and the resolver-provided display name second. The executor SHALL persist the HTML via `HtmlImportStorage` (same store used by the in-app file-import flow), create a `WebViewModel` with a synthesised `file:///webspace_import_<microseconds>.html` `initUrl`, register the new site, activate it, and apply the current theme. The picker's "open in existing site" and "bind to site" options SHALL NOT be offered for HTML payloads, because an existing site cannot meaningfully claim opaque file content (no host, no domain) — only the create path is sensible.

#### Scenario: HTML payload short-circuits picker

- **GIVEN** the user has two existing sites
- **WHEN** another app shares an HTML file to WebSpace
- **THEN** the engine emits `DispatchCreateSiteFromHtml`
- **AND** no picker is shown
- **AND** a new file:// site is created with the file's HTML stored in `HtmlImportStorage`

#### Scenario: HTML title preferred over filename

- **GIVEN** a shared HTML file containing `<title>Bookmarks</title>` and a filename `export-2026-04-19.html`
- **WHEN** the share is dispatched
- **THEN** the new site's `name` is `Bookmarks`

#### Scenario: HTML filename used when no title

- **GIVEN** a shared HTML file with no `<title>` and filename `notes.html`
- **WHEN** the share is dispatched
- **THEN** the new site's `name` is `notes`

#### Scenario: HTML shared as text/plain via content URI is still imported

- **GIVEN** a file manager shares an `.html` file to WebSpace as `text/plain` via a `content://` URI whose path is an opaque document id
- **WHEN** the Android intent handler processes the `EXTRA_STREAM`
- **THEN** the handler resolves the provider type / display name (or sniffs the bytes) and recognises the payload as HTML
- **AND** the dispatcher emits `DispatchCreateSiteFromHtml` rather than silently dropping the share

#### Scenario: iOS HTML file share creates a new site

- **GIVEN** the user shares an `.html` file from Files (or another app) to WebSpace on iOS
- **WHEN** the Share Extension reads the document, writes it to the app-group container, and wakes the app via `webspace://openhtml`
- **THEN** the app's next `consumeLaunchHtml` poll drains the container and the dispatcher emits `DispatchCreateSiteFromHtml`
- **AND** the app-group copy is deleted so a later poll does not re-import the same file

#### Scenario: Empty HTML payload is unsupported

- **WHEN** the engine receives an `InboundHtml` with empty content
- **THEN** the engine emits `DispatchUnsupported`
- **AND** no site is created

---

### Requirement: LIR-009 - No-Match Recovery With Stripped-Path Site Creation

When the resolver returns no match for an incoming URL, the system SHALL offer to create a new site for that URL whose `initUrl` is the incoming URL **with path, query, and fragment stripped** (only `<scheme>://<host>[:port]/` is retained). The arrived URL is still loaded into the new site's webview on first activation, but the site's persisted "home" `initUrl` is the stripped form, so subsequent app launches and navigation-engine same-domain checks operate on the site root rather than on a deep article URL. The synthesized claim is `[baseDomain(getBaseDomain(host))]` per LIR-001. The stripping rule SHALL reject non-`http`/`https` URLs and URLs with empty hosts, returning to a no-op (snackbar) rather than creating a malformed site.

#### Scenario: Share-sheet no-match prompts create with stripped path

- **GIVEN** no site matches `https://example.org/articles/2026/feature?ref=share#top`
- **WHEN** the URL arrives via iOS Share Extension, Android `ACTION_SEND`, or `webspace://`
- **THEN** the app shows a "Create site for example.org?" bottom sheet
- **AND** accepting creates the site with `initUrl == "https://example.org/"`
- **AND** the new site's webview navigates to the full incoming URL on first activation
- **AND** the synthesized `domainClaims` is `[baseDomain("example.org")]`

#### Scenario: Stripped path preserves non-default port

- **GIVEN** no site matches `http://localhost:8080/dashboard?token=abc`
- **WHEN** the user accepts the create prompt
- **THEN** the new site's `initUrl == "http://localhost:8080/"`

#### Scenario: Malformed target rejected

- **GIVEN** the dispatched URL has an empty host (e.g. `https:///foo`) or a non-http(s) scheme
- **WHEN** the no-match flow runs
- **THEN** no site is created
- **AND** a snackbar reports the URL was unsupported

---

### Requirement: LIR-010 - Three-Option Dispatch Picker

Whenever an inbound URL cannot be unambiguously dispatched by the resolver alone — that is, the resolver returns ambiguous (LIR-002 tie) or no-match (LIR-009) — the system SHALL surface a single bottom-sheet picker offering up to three options, in this order:

1. **Match router default** — activate the resolver's top-scored match. This option SHALL be present whenever the resolver returned a single winning candidate (i.e. on ambiguous, listed once per tied candidate; on no-match, suppressed).
2. **Send domain (and subdomains) to a site** — open a site picker listing every existing site. When the global `linkHandlingClaimDomains` setting is enabled (opt-in; default **off**), selecting a site SHALL append `[exactHost(host), wildcardSubdomain(getBaseDomain(host))]` to that site's `domainClaims` (deduplicated against existing entries), persist the change, and then activate the site on the full incoming URL. When `linkHandlingClaimDomains` is disabled (the default), selecting a site SHALL merely open the incoming URL in that site (in its main webview when in-domain, nested otherwise — identical to picking a router-default "Open in <site>" row) WITHOUT mutating the site's `domainClaims`; the picker labels this row "Open <host> in a site" rather than "Send <host> (and subdomains) to a site". This option SHALL be suppressed when the user has zero existing sites. The claim-vs-open branch is owned by the engine entry point `sendToSite(inbound, site, claimDomain)` so the view never decides it.
3. **Create new site (stripped path)** — invoke the LIR-009 flow. This option SHALL be suppressed when the URL's host is empty or its scheme is not `http`/`https`.

The picker SHALL be skipped (option 1 silently auto-applied) when the resolver returned exactly one match — that is the normal "router default" fast path. The picker SHALL be reachable manually from a per-site or settings affordance (e.g. long-press on the share-sheet target during testing) so the user can re-route a URL even when a single resolver match exists; the manual entry point still uses LIR-010 semantics.

When option 2 is taken and the chosen site already has a claim that would have matched the URL on its own, the dispatch SHALL still complete (idempotent: `claimsToAdoptHost` deduplicates) and no error SHALL be surfaced.

#### Scenario: No match shows two options

- **GIVEN** the user has two existing sites and none match `https://forum.invalid/thread/42`
- **WHEN** the URL arrives via share intent
- **THEN** the picker shows "Send forum.invalid to <pick site>" and "Create new site for forum.invalid"
- **AND** "Match router default" is not shown (no resolver winner)

#### Scenario: Tie shows router-default rows plus the binding/create options

- **GIVEN** two sites both claim `exactHost:reddit.com`
- **WHEN** `https://reddit.com/r/flutter` arrives
- **THEN** the picker shows one "Open in <Site A>" row, one "Open in <Site B>" row, "Send reddit.com (and subdomains) to a site", and "Create new site for reddit.com"

#### Scenario: Bind to existing site mutates its claims

- **GIVEN** `linkHandlingClaimDomains` is enabled
- **AND** site A exists with no claim covering `forum.invalid`
- **WHEN** the user picks "Send forum.invalid to Site A" for `https://forum.invalid/thread/42`
- **THEN** site A's `domainClaims` gains `exactHost:forum.invalid` and `wildcardSubdomain:forum.invalid`
- **AND** the change persists across app restart
- **AND** site A is activated and navigates to `https://forum.invalid/thread/42`
- **AND** a future arrival of `https://sub.forum.invalid/x` resolves to site A without showing the picker

#### Scenario: Default (claim setting off) opens without mutating claims

- **GIVEN** `linkHandlingClaimDomains` is disabled (the default)
- **AND** site A exists with no claim covering `forum.invalid`
- **WHEN** the user picks "Open forum.invalid in a site" → Site A for `https://forum.invalid/thread/42`
- **THEN** site A's `domainClaims` is unchanged
- **AND** the incoming URL opens in site A (nested, since it is out-of-domain) carrying site A's privacy settings
- **AND** a future arrival of `https://forum.invalid/x` does NOT resolve to site A and re-shows the picker

#### Scenario: No existing sites suppresses option 2

- **GIVEN** the user has zero existing sites (fresh install)
- **WHEN** any URL arrives
- **THEN** only "Create new site" is offered (option 2 hidden)

#### Scenario: Single resolver match skips the picker

- **GIVEN** site A exclusively claims `exactHost:twitter.com`
- **WHEN** `https://twitter.com/user` arrives
- **THEN** site A is activated immediately
- **AND** no picker is shown

#### Scenario: Idempotent re-binding

- **GIVEN** site A already claims `wildcardSubdomain:example.org`
- **WHEN** the user invokes the manual picker on `https://api.example.org/x` and chooses "Send to site A"
- **THEN** the dispatch succeeds
- **AND** site A's claim list does not gain a duplicate entry
