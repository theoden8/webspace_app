## MODIFIED Requirements

### Requirement: CAPTCHA-008 - The captcha allow follows the navigation decision

The captcha allow SHALL be applied **after** the navigation verdict, in
**both** interception paths — a fix to one leaves the other open, since
`onUrlChanged` catches exactly the server-side and script-driven
navigations that `shouldOverrideUrlLoading` did not:

- `shouldOverrideUrlLoading` — after `config.shouldOverrideUrlLoading`
  (the nested-url-blocking engine, see
  [nested-url-blocking](../nested-url-blocking/spec.md)) has returned.
- `NavigationDecisionEngine.decideOnUrlChanged` — after the
  no-gesture branch (NESTED-004).

Taken first, a URL that merely looks like a captcha would skip
the user-gesture requirement and cross-domain nested routing, and could navigate the parent webview to any origin — inside the
site's own container, and committed as its persisted `currentUrl`.

#### Scenario: A captcha-shaped URL still goes through the routing decision

**Given** any site (every site blocks gesture-less cross-domain navigations)
**And** a script-driven navigation to a cross-domain URL whose path
contains a Cloudflare marker
**When** `shouldOverrideUrlLoading` runs
**Then** the navigation decision engine sees the URL
**And** its verdict is honored before the captcha allow is considered

#### Scenario: The onUrlChanged path enforces the same order

**Given** a site with no recent gesture
**When** `onUrlChanged` fires for
`https://attacker.example/cdn-cgi/challenge-platform/x`
**Then** `decideOnUrlChanged` returns `blockSilent`

#### Scenario: A genuine interstitial is unaffected

**Given** the same site
**When** `onUrlChanged` fires for
`https://site.example/cdn-cgi/challenge-platform/h/b/orchestrate`
**Then** the same-domain check returns `allow` before the captcha branch is
reached
