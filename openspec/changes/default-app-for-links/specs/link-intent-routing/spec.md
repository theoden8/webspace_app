## ADDED Requirements

### Requirement: LIR-001 - Per-Site Domain Claim List

Each site SHALL carry a list of domain claims that declare which URLs it handles. A claim has a `kind` of `exactHost`, `wildcardSubdomain`, or `baseDomain`, and a canonical lowercase `value` with no scheme or port. Existing sites SHALL auto-synthesize one `baseDomain` claim equal to `getBaseDomain(initUrl)` on first load after upgrade, preserving legacy cookie-isolation semantics.

#### Scenario: Legacy site migrates with synthesized claim

- **WHEN** a `WebViewModel` is deserialized from JSON that does not contain `domainClaims`
- **THEN** the site's in-memory `domainClaims` is `[DomainClaim(baseDomain, getBaseDomain(initUrl))]`
- **AND** subsequent serialization omits `domainClaims` when it equals the synthesized default

#### Scenario: User defines multiple claims on one site

- **WHEN** the user saves claims `[exactHost:google.com, wildcardSubdomain:google.com, exactHost:gmail.com]` on a Google site
- **THEN** the site stores all three claims verbatim
- **AND** `google.com`, `mail.google.com`, and `gmail.com` all route to that site via the resolver

---

### Requirement: LIR-002 - URL Routing Resolver

The system SHALL resolve an incoming https URL to exactly one site (or "no match") using a deterministic specificity ranking: `exactHost` (score 300) > `wildcardSubdomain` (score 200) > `baseDomain` (score 100). On a score tie, the system SHALL surface a disambiguation picker.

#### Scenario: Exact host beats wildcard

- **WHEN** site A claims `wildcardSubdomain:mastodon.social` and site B claims `exactHost:mastodon.social`
- **AND** the incoming URL is `https://mastodon.social/@user`
- **THEN** the resolver returns site B

#### Scenario: Wildcard matches subdomain but not base

- **WHEN** site A claims `wildcardSubdomain:mastodon.social` only
- **AND** the incoming URL is `https://mastodon.social/`
- **THEN** the resolver returns no match from site A's wildcard claim
- **AND** falls through to any `baseDomain` or `exactHost` claim on other sites

#### Scenario: Tie surfaces picker

- **WHEN** two sites both claim `exactHost:reddit.com`
- **AND** the incoming URL is `https://reddit.com/r/flutter`
- **THEN** a disambiguation picker is shown listing both sites
- **AND** the chosen site receives the full URL

#### Scenario: No match falls back

- **WHEN** no site's claims match the incoming URL
- **AND** the launch source is an Android intent
- **THEN** the resolver returns no match
- **AND** the intent is re-emitted to the OS chooser excluding WebSpace

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

### Requirement: LIR-004 - Android Share Intent Handler

The Android app SHALL declare an `ACTION_SEND` intent-filter with `mimeType="text/plain"` on `MainActivity`. Shared text that starts with `http://` or `https://` (after trimming) SHALL be delivered to the resolver.

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

---

### Requirement: LIR-005 - Android Curated Open Intent Handlers

The Android app SHALL register one `<activity-alias>` per curated host, each with `ACTION_VIEW` + `android.intent.category.BROWSABLE` + `<data android:scheme="https" android:host="..."/>`, `android:autoVerify="false"`, and `android:enabled="false"` by default. Users SHALL toggle each alias from the Link handling settings screen, which calls `PackageManager.setComponentEnabledSetting` via a platform channel.

#### Scenario: User enables twitter.com handler

- **GIVEN** `com.theoden8.webspace/.handler.TwitterHandler` alias exists and is disabled
- **WHEN** the user flips the twitter.com toggle on
- **THEN** the app calls `setComponentEnabledSetting(..., COMPONENT_ENABLED_STATE_ENABLED, DONT_KILL_APP)`
- **AND** the next time the user taps a twitter.com link in another app, WebSpace appears in the chooser

#### Scenario: User disables handler

- **WHEN** the user flips a host's toggle off
- **THEN** the corresponding alias is set to `COMPONENT_ENABLED_STATE_DISABLED`
- **AND** WebSpace no longer appears in the chooser for that host

#### Scenario: No autoVerify

- **WHEN** any alias is enabled
- **THEN** its `<intent-filter>` carries `android:autoVerify="false"`
- **AND** Android never selects WebSpace silently as default handler

---

### Requirement: LIR-006 - iOS Share Extension

The iOS app SHALL ship a Share Extension target that accepts Web URLs (`NSExtensionActivationSupportsWebURLWithMaxCount = 1`). The extension SHALL hand the URL to the main app via `extensionContext.open(URL(string: "webspace://open?url=<encoded>")!)` and then call `completeRequest(returningItems: nil)`. The main app SHALL handle the `webspace://open` URL by passing the decoded URL to the resolver.

#### Scenario: Share from Safari

- **GIVEN** the user is on an article in Safari
- **WHEN** the user taps the share button and selects WebSpace
- **THEN** the Share Extension launches briefly
- **AND** the main app opens with the article URL routed to the matching site
- **AND** the OS shows a "← Safari" breadcrumb in the status bar

#### Scenario: Share Extension with no URL

- **WHEN** the share sheet contains only text without a URL
- **THEN** WebSpace does not appear in the share sheet (filtered by `NSExtensionActivationRule`)

---

### Requirement: LIR-007 - macOS Share Extension

The macOS app SHALL ship a Share Extension target with behavior equivalent to iOS (LIR-006). Data transfer to the main app uses the same `webspace://open` scheme and App Group.

#### Scenario: Share from Safari on macOS

- **WHEN** the user shares a URL from Safari to WebSpace
- **THEN** the main app opens with the URL routed to the matching site

---

### Requirement: LIR-008 - Back to Referring App

When launched via share/open intent from another app, pressing Back (Android) or tapping the status-bar breadcrumb (iOS/macOS) SHALL return the user to the referring app without first returning to the WebSpace home.

#### Scenario: Android back returns to referrer

- **GIVEN** the user tapped a link in Gmail and chose WebSpace
- **WHEN** the matching site is loaded and the user presses the system Back button
- **THEN** the user returns to Gmail
- **AND** WebSpace is not relaunched into its home state

#### Scenario: iOS breadcrumb returns to referrer

- **GIVEN** the user shared a URL from Safari to WebSpace
- **WHEN** the user taps the "← Safari" breadcrumb in the status bar
- **THEN** Safari reopens at its previous state

---

### Requirement: LIR-009 - Link Handling Settings Screen

The app SHALL provide a "Link handling" screen inside Settings containing: a master "Handle shared links" switch, per-host toggles (Android only; reflect actual component state), and a "Routing overview" list showing every domain pattern → owning site with conflict warnings.

#### Scenario: Master switch disabled

- **WHEN** the user turns off the master switch
- **THEN** Android disables every alias regardless of individual toggle state
- **AND** iOS/macOS extensions detect the flag via App Group and no-op

#### Scenario: Routing overview reflects claims

- **GIVEN** site A claims `exactHost:twitter.com`, `exactHost:x.com`
- **WHEN** the user opens the Routing overview
- **THEN** both patterns are listed with site A as the owner

#### Scenario: Tap row opens site editor

- **WHEN** the user taps a row in the Routing overview
- **THEN** the owning site's editor opens scrolled to the domain-claim list

---

### Requirement: LIR-010 - No-Match Recovery

When the resolver returns no match for an incoming URL, the system SHALL offer to create a new site for that URL rather than silently failing, except when the launch source is an Android OS chooser (in which case no match simply re-emits the intent).

#### Scenario: Share sheet no-match prompts create

- **GIVEN** no site matches `https://example.org/article`
- **WHEN** the URL arrives via iOS Share Extension or Android `ACTION_SEND`
- **THEN** the app shows a "Create site for example.org?" bottom sheet
- **AND** accepting creates a site with `initUrl=https://example.org/article` and a synthesized `baseDomain` claim
