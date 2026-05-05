# Always Open Home

## Purpose

A per-site `alwaysOpenHome` toggle that makes the site's *navigation
URL* ephemeral while keeping its persistent state (cookies,
localStorage, IndexedDB, HTTP cache) intact. The site reverts to its
`initUrl` on **app restart** and on **Android home-shortcut tap**, but
the user's logged-in session, preferences, and other cookie-backed
state survive both events.

Two motivating cases the user split out from
[incognito-mode](../incognito-mode/spec.md) (which ALSO drops
cookies):

- **Banking** — cookies persist so login/2FA stays streamlined, but
  every entry lands on the login screen rather than a "session expired"
  redirect from a deep account page.
- **Weather** — cookies persist so a saved city / unit preference
  survives, but the site reopens at the home-town view rather than
  whatever city the user last drifted to.

[Incognito mode](../incognito-mode/spec.md) implies `alwaysOpenHome`
as a strict subset: an incognito site already drops `currentUrl` on
serialize and reloads home on shortcut tap; the additional
incognito-only effect is the cookie / localStorage wipe.

## Status

- **Date**: 2026-05-05
- **Status**: Implemented

---

## Requirements

### Requirement: AOH-001 - URL State Is Stripped On Serialization

The system SHALL omit `currentUrl` and `pageTitle` from the JSON
produced by `WebViewModel.toJson` when `alwaysOpenHome = true`. The
`cookies` list and every other persistent field SHALL be retained
unchanged on the same call.

#### Scenario: Always-open-home JSON omits currentUrl

**Given** a `WebViewModel` with `alwaysOpenHome = true`, `incognito = false`, and `currentUrl != initUrl`
**When** `toJson()` is called
**Then** the resulting map does NOT contain a `currentUrl` key
**And** does NOT contain a `pageTitle` key
**And** the `cookies` list reflects the in-memory list (unchanged)

#### Scenario: Plain site JSON retains URL

**Given** a `WebViewModel` with `alwaysOpenHome = false` and `incognito = false`
**When** `toJson()` is called
**Then** `currentUrl` is present
**And** `pageTitle` is present (may be null)

---

### Requirement: AOH-002 - URL State Is Discarded On Deserialization

The system SHALL discard any persisted `currentUrl` / `pageTitle` when
a `WebViewModel` is rehydrated with `alwaysOpenHome = true`. This
covers JSON written by older builds (defense in depth) and JSON
imported from settings backups.

#### Scenario: Legacy JSON with alwaysOpenHome + currentUrl

**Given** a JSON map written by a build that did not strip on toJson, with `alwaysOpenHome: true` and `currentUrl: "https://www.bank.example/account/123"`
**When** `WebViewModel.fromJson(json, ...)` is called
**Then** the resulting model's `currentUrl` equals its `initUrl`
**And** the resulting model's `pageTitle` is null
**And** the resulting model's `cookies` reflect the persisted list (NOT cleared)

---

### Requirement: AOH-003 - Cookies Are Preserved

The toggle SHALL NOT clear cookies, localStorage, IndexedDB, HTTP
cache, or any other persistent per-site store on serialize, on
deserialize, on shortcut tap, or on app start. The semantic boundary
between `alwaysOpenHome` and [incognito](../incognito-mode/spec.md) is
exactly that: incognito wipes session storage, alwaysOpenHome leaves
it alone.

#### Scenario: Banking site cookies survive app restart

**Given** a banking site with `alwaysOpenHome = true` and a logged-in session cookie
**When** the user kills the app and relaunches
**Then** the site's webview loads at `initUrl` (e.g. login URL)
**And** the persisted cookie is restored from `CookieSecureStorage`
**And** the bank redirects the login page to the dashboard automatically (or session continues seamlessly)

---

### Requirement: AOH-004 - Webspace-Scoped Reset On Shortcut Tap

The system SHALL reset `currentUrl` to `initUrl` for every flagged
site that shares at least one named webspace with the launched site
when the user taps an Android home-shortcut. A site is "flagged"
when `alwaysOpenHome = true` or `incognito = true`. The launched site
itself is reset whenever it is flagged. The synthetic "All" webspace
MUST NOT count as shared membership for this rule.

The reset SHALL apply to both cold launches via shortcut (overlapping
with [HS-006](../home-shortcut/spec.md), which already resets the
launched site itself regardless of its flag) and warm taps while the
app is already running.

#### Scenario: Warm shortcut tap resets banking siblings

**Given** webspace "Banking" contains site A (login.bank.example) and site B (login.creditcard.example), both with `alwaysOpenHome = true`
**And** the app is running and B is currently active and has navigated to `https://login.creditcard.example/account/123`
**And** the user is currently in the "Banking" webspace
**When** the user taps A's home-screen shortcut
**Then** A becomes active
**And** A's webview is created with URL `initUrl` (or stays at `initUrl` if not yet built)
**And** B's webview is disposed
**And** B's `currentUrl` is reset to its `initUrl`
**And** the next time B is shown, it reloads at `initUrl`

#### Scenario: Webspace boundary keeps unrelated flagged sites untouched

**Given** webspace "Banking" contains site A (`alwaysOpenHome = true`)
**And** webspace "Mail" contains site C (`alwaysOpenHome = true`), distinct from "Banking"
**And** A and C share no named webspace
**When** the user warm-taps A's home-screen shortcut
**Then** A resets to its initUrl
**And** C's currentUrl is unchanged

#### Scenario: Unflagged launched site still gets HS-006 cold-reset

**Given** site A has `alwaysOpenHome = false`
**And** the user cold-launches the app via A's home shortcut
**Then** A's currentUrl resets to its initUrl per [HS-006](../home-shortcut/spec.md)
**And** no flagged sibling propagation runs against A's webspace if A's flag is false (the flag controls the propagation; sibling flagged sites in A's webspace still reset because the propagation is anchored on the launched site, not gated by its own flag)

---

### Requirement: AOH-005 - Incognito Implies Always Open Home

A site with `incognito = true` SHALL be treated by the URL-stripping
and shortcut-reset paths as if `alwaysOpenHome` were also true,
regardless of the stored `alwaysOpenHome` value.

#### Scenario: Incognito serialization drops URL

**Given** a `WebViewModel` with `incognito = true` and `alwaysOpenHome = false`
**When** `toJson()` is called
**Then** the resulting map does NOT contain `currentUrl` or `pageTitle`
**And** the `cookies` list is empty (incognito's separate contract — see [INC-003](../incognito-mode/spec.md))

#### Scenario: Settings UI grays out the toggle when incognito is on

**Given** the user opens per-site settings for a site with `incognito = true`
**When** the page renders
**Then** the "Always open Home" switch is shown ON
**And** the switch is disabled (no `onChanged` callback)
**And** the subtitle reads "Forced on by Incognito"

---

## Implementation

### Files

#### Modified

- `lib/web_view_model.dart` — `alwaysOpenHome` field, ctor param,
  `toJson` URL-strip gate, `fromJson` URL-strip gate.
- `lib/main.dart` — `_resetAlwaysOpenHomeOnShortcut(int)` helper
  invoked from `_restoreAppState` (cold) and `_handleShortcutIntent`
  (warm).
- `lib/services/webspace_selection_engine.dart` —
  `indicesToResetOnShortcutLaunch` pure helper computes the reset set
  from the launched index + the webspaces list + a flag predicate.
- `lib/screens/settings.dart` — per-site `SwitchListTile` for the
  toggle, gated on `_incognito`.

#### Tests

- `test/web_view_model_test.dart` — toJson/fromJson scenarios for the
  new flag.
- `test/webspace_selection_engine_test.dart` —
  `indicesToResetOnShortcutLaunch` cases.
