# Content Blocker — per-site filter-list mask delta

## ADDED Requirements

### Requirement: CB-015 - Per-Site Filter-List Mask

Each site SHALL have a `disabledFilterLists` setting (default: empty) naming
filter list ids the site opts out of. It is a mask over the app-wide
selection: a list not enabled in App Settings is not in the engine at all, so
naming it here does nothing.

The mask SHALL be carried by the rules, not by the decision path. At engine
build time each masked list's text is rewritten with adblock-rust's own domain
scoping by
[`scopeRulesAwayFromHosts`](../../../../../lib/services/filter_list_mask.dart):

- network rules gain `$domain=~<host>`, merged into an existing `domain=` or
  `from=` option rather than appended as a second one, which would replace it;
- cosmetic rules gain `~<host>` in their domain list.

One engine therefore answers every site, and no per-request work consults the
mask. The rewrite MUST classify rules the way adblock-rust 0.12 does — the
LAST `$` opens the option list, options split on `,`, and
`detect_filter_type`'s comment and cosmetic tests decide the shape — because a
rule the rewrite mis-parses is silently dropped rather than visibly wrong.

`<host>` is the site's registrable host, which is what `$domain=` matches
against. Negated domains cover subdomains, so `example.com` covers
`www.example.com`.

The mask SHALL be persisted (`content_blocker_list_masks`) so the first engine
build of a launch already carries it — otherwise every launch parses the whole
rule set twice. It is derived from the sites and rewritten whenever they are
saved, so a stale copy self-heals.

Rebuilding is the cost of a mask change, so the mask SHALL be re-applied only
when it actually differs from the one in force.

**Left global by design.** Three rule shapes SHALL NOT be scoped, because
scoping them changes what they do for every site rather than exempting one:

- `$badfilter` — it cancels another rule by matching its options, so an added
  `$domain=` breaks the cancellation everywhere;
- cosmetic unhide (`#@#`, `#@?#`, `#@$#`, `#@%#`) — adblock-rust rejects a rule
  that is both an unhide and domain-negated (`DoubleNegation`) and drops it;
- generic scriptlet, procedural and action rules (`##+js(...)`,
  `##sel:remove()`, `#?#...`) — a generic rule with only negated hostnames goes
  on applying elsewhere *only* for plain hides (`hidden_generic_rule`); for
  these shapes it would apply nowhere. Generic procedurals also ride the
  synthetic-host backfill, which is queried once for every site.

Archive-tier sites SHALL carry no mask (ARCH-006): the rewrite changes the
shared engine cache blob, whose contents must not vary with whether an archive
is open.

The iOS/macOS interceptor's prefilter is derived from the same rewritten text,
so `parseAbpNetworkPrefilter` SHALL strip a rule's options before classifying
it. A regex rule reads as a regex only by its trailing `/`, and every masked
rule now carries a `$domain=` after it: classified as a plain pattern, a regex
would be tokenized on a literal it does not guarantee, and the prefilter would
hard-allow a request the engine blocks.

#### Scenario: A masked regex rule still forces a round-trip

**Given** a masked list carries a regex network rule
**When** the interceptor prefilter is rebuilt
**Then** the rule contributes no token
**And** the prefilter reports untokenizable rules, so a host-Bloom miss still
round-trips to the engine

#### Scenario: A site switches one list off

**Given** EasyList and EasyPrivacy are enabled app-wide
**And** a site switches EasyList off
**When** that site's page requests a URL only an EasyList rule blocks
**Then** the request is allowed
**And** the same request is still blocked on every other site
**And** EasyPrivacy still applies to the site

#### Scenario: The negation reaches subdomains

**Given** a site on `example.com` masks a list off
**When** a page on `www.example.com` requests a URL that list blocks
**Then** the request is allowed

#### Scenario: An already-scoped rule keeps its scoping

**Given** a masked list carries `||ads.example^$domain=news.example`
**Then** the rule still applies on `news.example`
**And** it applies on neither the masked site nor anywhere else it did not
before

#### Scenario: A masked generic hide stays generic

**Given** a masked list carries `##.ad-banner`
**Then** the selector is still hidden on other sites through the generic
class/id scanner
**And** on the masked site it comes back as an exception, so the scanner drops
it

#### Scenario: Android sub-resources carry the mask

**Given** a site masks a list off
**When** its page fetches a sub-resource on Android
**Then** the native engine, which is fed the same rewritten rules, allows it

#### Scenario: A mask that did not change costs nothing

**Given** the sites are saved with no change to any site's list selection
**Then** the engine is not rebuilt

## MODIFIED Requirements

### Requirement: CB-006 - Per-Site Toggle

Each site SHALL have a `contentBlockEnabled` setting (default: `true`) that
controls whether ABP filtering is applied, and a `disabledFilterLists` setting
(default: empty) that controls *which* lists apply when it is (CB-015). The
toggle wins: with it off the site runs no filter list.

Both settings SHALL ride the nested-webview config so a cross-domain link
inherits them.

#### Scenario: Disable content blocking for a site

**Given** a site has content blocking disabled in its settings
**When** the site loads
**Then** no domain blocking, CSS hiding, or text hiding is applied

#### Scenario: Default enabled

**Given** a new site is created
**Then** `contentBlockEnabled` defaults to `true`

#### Scenario: Default list selection is every app-wide list

**Given** a new site is created
**Then** `disabledFilterLists` is empty
**And** the site runs whatever App Settings has enabled

#### Scenario: Setting persists

**Given** a site has content blocking disabled
**When** the app is restarted
**Then** the setting remains disabled

#### Scenario: Enabling the toggle with no rules loaded warns

**Given** no filter lists have been downloaded (engine has no rules)
**When** the user enables the Content Blocker toggle in site settings
**Then** the toggle flips (the setting persists and takes effect once lists are downloaded)
**And** a SnackBar warns that the feature has no downloaded data and points at App Settings
**And** while the toggle is on without data, a warning icon renders next to the title and the "Not configured" subtitle is amber

#### Scenario: Enabling Tracking Protection with unconfigured blockers warns

**Given** Tracking Protection forces the DNS blocklist and Content Blocker on
**And** at least one of them has no downloaded data
**When** the user enables the Tracking Protection toggle
**Then** the same SnackBar warning fires, naming each unconfigured feature
**And** the Tracking Protection tile carries the warning icon while a forced blocker is unconfigured
**And** the forced blocker's subtitle joins the forced text with "Not configured"

#### Scenario: Propagates to nested webviews

**Given** a site has content blocking enabled
**When** a cross-domain link opens in a nested InAppBrowser
**Then** the nested webview also has content blocking enabled
**And** it carries the same `disabledFilterLists`

#### Scenario: The list row appears only when the blocker is on

**Given** a site with the content blocker on and at least one list enabled
app-wide
**Then** a "Filter lists" row sits under the toggle
**And** its subtitle reports how many of those lists apply to this site
