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

The iOS app SHALL ship a Share Extension target that accepts Web URLs (`NSExtensionActivationSupportsWebURLWithMaxCount = 1`). The extension SHALL hand the URL to the main app via `extensionContext.open(URL(string: "webspace://open?url=<encoded>")!)` and then call `completeRequest(returningItems: nil)`. The main app SHALL handle the resulting `webspace://open` URL via LIR-004.

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

The app SHALL provide a "Link handling" screen inside Settings containing a master "Handle shared links" switch and a "Routing overview" list showing every domain pattern → owning site with conflict warnings.

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

### Requirement: LIR-009 - No-Match Recovery

When the resolver returns no match for an incoming URL, the system SHALL offer to create a new site for that URL. Accepting creates a `WebViewModel` whose `initUrl` is the incoming URL and whose `domainClaims` is the synthesized `[baseDomain(getBaseDomain(host))]`.

#### Scenario: Share-sheet no-match prompts create

- **GIVEN** no site matches `https://example.org/article`
- **WHEN** the URL arrives via iOS Share Extension or Android `ACTION_SEND` or `webspace://`
- **THEN** the app shows a "Create site for example.org?" bottom sheet
- **AND** accepting creates the site and immediately activates it on the article URL
