## MODIFIED Requirements

### Requirement: NESTED-009 - Per-Site Open External Links in System Browser

The system SHALL provide a per-site choice of where a cross-domain link not
covered by the site's domain claims goes: a nested in-app webview, the
device's default browser, or nowhere.

**Field**: `externalLinkMode`: `inApp` (default), `browser` or `block`. It
replaced the `externalLinksInBrowser` bool; a stored `externalLinksInBrowser:
true` with no `externalLinkMode` SHALL read as `browser`, and an unknown or
wrong-typed value as `inApp`. `toJson` SHALL omit the field at `inApp`.

A navigation that the cross-domain decision would route to a nested webview
(NESTED-004 "Direct link click allowed") SHALL, when its target matches one of
the site's `effectiveDomainClaims` (link-intent-routing), open in a nested
webview in every mode. Otherwise:

- `inApp`: it opens in a nested webview (`blockOpenNested`).
- `browser`: it is handed to the system browser via `url_launcher`
  (`blockOpenExternal`).
- `block`: it is cancelled and nothing opens (`blockOutbound`). Only top-level
  navigations reach the decision, so images, scripts, styles and frames from
  other domains still load. When the navigation carried a user gesture the app
  SHALL say so with a short message naming the target host; a gesture-less
  one SHALL be cancelled without any UI, so a page cannot flood the screen.

The `blockAutoRedirects` silent block and the background-site suppression take
precedence in every mode, so a gesture-less script redirect or a background
site never pops the system browser or the blocked message. Archive-tier sites
SHALL read `browser` as `inApp` (`effectiveExternalLinkMode`, ARCH-006):
handing a URL to another app crosses the archive isolation boundary. `block`
crosses nothing and SHALL stay in force for them.

Outbound routing (link-intent-routing LIR-014) is an option of the `inApp`
mode only.

The browser mode implements discussion #438: "a setting for each site to have
any link inside a web app that is not a domain claim for that website to open
in the system's default browser." The block mode implements issue #629: a site
that cannot take the user to another site. In-app navigation never mutates
`domainClaims`; claims change only through the per-site editor or the
user-initiated inbound bind picker (link-intent-routing LIR-010).

#### Scenario: Unclaimed cross-domain link opens in the system browser

**Given** a site `https://example.com` in the `browser` mode
**And** the user taps a link to `https://unclaimed.com` (cross-domain, not a claim)
**When** `shouldOverrideUrlLoading` runs
**Then** the navigation is cancelled
**And** the URL is handed to the device's default browser
**And** no nested webview opens

#### Scenario: Unclaimed cross-domain link is blocked

**Given** a site `https://example.com` in the `block` mode
**When** the user taps a link to `https://unclaimed.com`
**Then** the navigation is cancelled
**And** neither a nested webview nor the system browser opens
**And** a short message says the link to `unclaimed.com` was blocked
**And** the site's page stays as it was

#### Scenario: A blocked script navigation says nothing

**Given** a site in the `block` mode with `blockAutoRedirects` off
**When** a script navigates the page to another domain with no user gesture
**Then** the navigation is cancelled and no message is shown

#### Scenario: Content from other domains still loads

**Given** a site in the `block` mode whose page embeds an image from `https://cdn.other.com`
**When** the page loads
**Then** the image loads: sub-resources are not navigations

#### Scenario: Claimed cross-domain link stays in the app

**Given** a "Google" site whose domain claims include `youtube.com`
**And** the site is in the `browser` or `block` mode
**When** the user taps a `https://youtube.com/...` link
**Then** the link opens in a nested webview (it matches a domain claim)

#### Scenario: Setting off preserves legacy routing

**Given** a site in the `inApp` mode (the default)
**When** the user taps a cross-domain link
**Then** it opens in a nested webview exactly as before

#### Scenario: The old switch migrates

**Given** site JSON written before this change with `externalLinksInBrowser: true`
**When** it is loaded
**Then** the site is in the `browser` mode
**And** its next save writes `externalLinkMode: "browser"` and no `externalLinksInBrowser`

#### Scenario: Gesture-less script redirect is not launched externally

**Given** a site in the `browser` mode with `blockAutoRedirects` on
**When** a script fires a cross-domain navigation with no user gesture
**Then** the navigation is silently cancelled (NESTED-004) and the system browser is NOT opened

#### Scenario: Archive-tier sites never hand a link to another app

**Given** an archive-tier site stored in the `browser` mode
**When** the user taps an unclaimed cross-domain link
**Then** it opens in a nested webview
**And** an archive-tier site in the `block` mode still blocks it

#### Scenario: Nested webview honors the setting

**Given** a claimed cross-domain link opened a nested webview while the site is in the `browser` or `block` mode
**When** the user taps a link in that nested webview pointing to a different domain than the page shown
**Then** that link opens in the system browser, or is blocked, as the mode says (NESTED-009 applies in nested screens too)

### Requirement: NESTED-010 - The Nested Screen Carries the Whole Per-Site Posture

Every per-site field the parent webview applies SHALL reach
`InAppWebViewScreen`. `LaunchUrlFunc`
([lib/web_view_model.dart](../../../lib/web_view_model.dart)) is the single
declaration of that chain; a field is threaded when it appears there, in
`_WebSpacePageState.launchUrl`, in the `InAppWebViewScreen` constructor, and
is read as `widget.<field>` inside the nested `WebViewConfig`.

A dropped field is not a cosmetic gap. `shouldOverrideUrlLoading` is null
unless the nested screen has a reason to build one, and null means allow — so
with `blockAutoRedirects` missing, one tap on an outbound link bought
unlimited gesture-less cross-origin redirects inside the parent's own
container. `blockedCookies`, the camera/microphone modes and their sources,
and `protectedContentAllowed` were missing for the same reason.

The nested `shouldOverrideUrlLoading` SHALL run
`NavigationDecisionEngine.decideShouldOverrideUrlLoading` with
`initUrl = _currentUrl` — the page shown here, not the opening site's home
URL, since a nested screen is already one hop out. It SHALL be non-null
whenever `blockAutoRedirects` is on or the external link mode is not `inApp`,
and null otherwise so default behaviour is byte-identical. A nested screen has
nowhere further to nest, so `blockOpenNested` navigates in place,
`blockOpenExternal` goes to the system browser, and `blockOutbound` opens
nothing.

`blockedCookies` SHALL be swept after every load here too — the nested
webview shares the parent's container, so a blocked cookie re-set through an
outbound link would otherwise come back. The sweep and its cookie reader are
wired only when the set is non-empty, so a site with no blocked cookies pays
no extra jar round-trip.

The camera / microphone / protected-content values passed SHALL be the
`effective*` getters, so an archive-tier or Tracking-Protection forced block
stays blocked one hop out (ARCH-006, ETP-023).

Regression gate: `test/nested_webview_field_parity_test.dart` reads the
typedef's parameters and fails when any one of them stops appearing in
`launchUrl`, in the constructor, or as a `widget.` read.

#### Scenario: A gesture-less redirect in a nested webview is blocked

**Given** the opening site has `blockAutoRedirects` on
**And** the user followed an outbound link into a nested webview
**When** the nested page script-navigates cross-domain with no gesture
**Then** `NavigationDecisionEngine.decideShouldOverrideUrlLoading` is run
with `initUrl` = the nested page's current URL
**And** the decision is `blockSilent`, so the navigation is cancelled

#### Scenario: A blocked cookie stays blocked one hop out

**Given** the opening site blocks the cookie `sid` on `ads.example`
**When** a page in the nested webview sets it
**Then** the nested screen deletes it from the shared container after the
load, exactly as the parent does

#### Scenario: A forced camera block survives the hop

**Given** an archive-tier site (`effectiveCameraMode == block`)
**When** it opens an outbound link and that page calls `getUserMedia`
**Then** the nested screen's in-memory mode starts at `block`
**And** no permission popup and no OS camera prompt appear
