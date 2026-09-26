## MODIFIED Requirements

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
