# UI Localization

## Status
**Implemented** (all `lib/main.dart`, `lib/screens/`, `lib/widgets/` strings routed through ARB; guard's `pending` set is empty)

## Purpose

Make every user-facing string in the app translatable, with English as the
authored source of truth, and guarantee no screen ever shows text that is not
backed by a translation key. Translations are produced by handing the
described English strings to a general-purpose model (or a human) rather than a
hosted translation platform (issue #406): no closed-source dependency, no
committed translation tooling, no human-coordination overhead.

## Problem Statement

UI strings were hardcoded English literals scattered across `lib/main.dart`,
`lib/screens/`, and `lib/widgets/` (~520 `Text(` widgets). There was no
localization infrastructure (`generate: true` in pubspec belonged to
`flutter_launcher_icons`; the README's "30+ languages" is per-site
`Accept-Language` spoofing, not UI translation). A localization effort needs:

- a single English source of truth that survives review,
- per-string descriptions so anyone (a general model or a person) can translate without organizing translators,
- a coverage signal so a half-translated locale cannot ship blank strings,
- enforcement that new code does not reintroduce hardcoded strings.

## Solution

ARB files under `lib/l10n/`, with `app_en.arb` as the template. The
translations ship as data: the app reads the active locale's ARB from its
assets at run time (LOC-012). `tool/gen_l10n.dart` generates only the typed
`AppLocalizations` API into `lib/l10n/gen/` (gitignored), with the signatures
Flutter's `gen_l10n` produced. The `MaterialApp` wires `AppLocalizations`
delegates and `supportedLocales`. Every key carries a `description` so a translator (human or
a general-purpose model) has the context to translate it; there is no committed
translation script, API key, or vendored prompt. Coverage and placeholder
parity are enforced in CI by Dart tests. Migration is phased behind a guard
whose enforced scope only grows.

---

## Requirements

### Requirement: LOC-001 - ARB source of truth

The English ARB SHALL be the single authored source of all UI strings, and
generated localization code SHALL NOT be committed.

#### Scenario: English template drives generation

- **Given** `lib/l10n/app_en.arb` with `@@locale: "en"` and one entry per UI string
- **When** `tool/gen_l10n.dart` runs (Gradle, Xcode and CMake run it before Dart is compiled; CI and `scripts/test_all.sh` run it after `pub get`)
- **Then** `AppLocalizations` is produced under `lib/l10n/gen/`
- **And** that directory is gitignored, reproducible by one command from a clean clone (`fvm dart tool/gen_l10n.dart`)

#### Scenario: Every key is documented

- **Given** a message key `k` in the template
- **Then** a sibling `@k` block exists with a non-empty `description`
- **And** `test/js/l10n_coverage.test.js` fails if any key lacks it

### Requirement: LOC-002 - No unkeyed user-facing text

A UI file SHALL NOT pass a raw string literal into a user-facing display
sink; all on-screen text SHALL resolve through `AppLocalizations`.

#### Scenario: Hardcoded literal in a UI file fails the build

- **Given** a file under `lib/main.dart`, `lib/screens/` or `lib/widgets/` not listed in `exempt` in `test/js/l10n_no_hardcoded_text.test.js`
- **When** it contains a literal opening a display sink (`Text(`, `SelectableText(`, `Tooltip(`, or `tooltip:`/`hintText:`/`labelText:`/`helperText:`/`errorText:`/`counterText:`/`prefixText:`/`suffixText:`/`semanticLabel:`)
- **Then** the guard test fails, naming the file and line
- **And** pure-data display (e.g. `host:port`) is extracted to a local variable so no literal sits inside a display widget

#### Scenario: New UI file cannot slip past the guard

- **Given** a new `.dart` file under `lib/main.dart`, `lib/screens/`, or `lib/widgets/`
- **When** it is added, with no edit to the guard
- **Then** the guard scans it like every other UI file

### Requirement: LOC-003 - Translation coverage gate

Every non-template locale ARB SHALL define exactly the template's keys, with
matching placeholder tokens and no empty values.

#### Scenario: Missing or empty translation fails CI

- **Given** a locale ARB `app_<x>.arb`
- **When** it omits a template key, or has an empty value
- **Then** `test/js/l10n_coverage.test.js` fails

#### Scenario: Placeholder drift fails CI

- **Given** a template string `"... {host}:{port} ..."`
- **When** the locale translation drops or renames a `{token}`
- **Then** the coverage test fails (interpolation would break)

#### Scenario: A translation that does not parse fails the build

- **Given** a locale ARB whose message for a template key is missing, has unbalanced braces or an invalid plural case, or reads a placeholder the template does not declare
- **When** `tool/gen_l10n.dart` runs
- **Then** it exits non-zero naming the file and key, so the build stops before a screen could show the message

#### Scenario: English-verbatim values are flagged as never-translated

- **Given** a template key back-filled into every locale ARB as a copy of the
  English value (key parity passes, but no actual translation happened)
- **When** the key's value equals the template value in **all** non-template
  locales and the key is not on the universal-token allowlist
- **Then** `test/js/l10n_coverage.test.js` fails, telling the maintainer to
  translate the key or add it to the allowlist
- **And** a value identical in only *some* locales (a real translation that
  coincides, e.g. `OK`, `URL`) does NOT fail, since the signal is "identical
  across the entire locale set," not a per-locale coincidence
- **And** the allowlist holds genuinely universal strings (brand/product
  names like `WebSpace`, `LocalCDN`, `ClearURLs`; acronyms like `DNS`, `GPS`,
  `SHA-256`; example hosts/URLs; and `auto`) so they never trip the guard

### Requirement: LOC-004 - Description-driven translation

Every template message SHALL carry a `description` so the strings can be
translated by handing the English ARB to any general-purpose model (or a human),
with no committed translation script, API key, or prompt in the repo.

#### Scenario: Each key is translatable from context alone

- **Given** a message key in `app_en.arb`
- **Then** its `@key.description` explains where/what the string is, written for someone who cannot see the screen
- **And** the coverage test fails if any description is missing or empty

#### Scenario: Adding a locale

- **Given** `app_en.arb` (values plus descriptions)
- **When** a translator or general model translates the values into locale `<x>`, keeping `{placeholder}` tokens verbatim, saved as `app_<x>.arb`
- **Then** the coverage test passes (key + placeholder parity, no empties)
- **And** no script, endpoint, or credential is required

### Requirement: LOC-005 - Phased migration

String migration SHALL proceed file-by-file, with the guard's enforced set
only growing.

#### Scenario: Migrating a file

- **Given** a file in `exempt`
- **When** all its strings are routed through `AppLocalizations` and keys added to `app_en.arb`
- **Then** it is removed from `exempt`
- **And** the migration is complete when `exempt` is empty

### Requirement: LOC-006 - MaterialApp wiring

The root `MaterialApp` SHALL register the localization delegates and supported
locales.

#### Scenario: Delegates registered

- **Given** the root `MaterialApp`
- **Then** `localizationsDelegates: AppLocalizations.localizationsDelegates`
- **And** `supportedLocales: AppLocalizations.supportedLocales`
- **And** the OS window title resolves via `onGenerateTitle` -> `appTitle`

### Requirement: LOC-012 - Translations ship as data

The app SHALL read each locale's messages from its ARB file at run time, so the
compiled code carries one copy of the localization API rather than one class
per locale. Formatting SHALL match what `gen_l10n` compiled in: placeholders by
name, and plurals through `Intl.pluralLogic` with `=0`/`=1`/`=2` folded into
`zero`/`one`/`two` and a later case overriding an earlier one.

#### Scenario: Only the active locale is read

- **Given** the ARB files declared as assets under `lib/l10n/`
- **When** `AppLocalizations.delegate.load(locale)` runs
- **Then** it reads the ARB of the most specific shipped locale (language, script and country, then fewer), decodes it once and caches it, parsing each message the first time it is formatted
- **And** `main()` reads the ARB of the locale the first frame resolves to before `runApp`, so the first frame's load completes synchronously
- **And** a later locale (the in-app override, a system change) is read asynchronously while the previous locale's text stays on screen

#### Scenario: Output matches the compiled classes

- **Given** a template message with placeholders or a plural
- **When** it is formatted for any shipped locale and count
- **Then** the text equals what `gen_l10n`'s generated class returned (compared for every message, every locale
  and plural counts 0 to 1001 when the runtime replaced it)
- **And** `test/icu_message_test.dart` holds the case folding, CLDR forms and locale fallback

#### Scenario: Tests read the checkout synchronously

- **Given** `test/flutter_test_config.dart`
- **Then** `ArbMessages.read` reads `lib/l10n/` from disk synchronously, so a widget test's first pump already has its text

---

## Implementation Notes

- Template [lib/l10n/app_en.arb](../../../lib/l10n/app_en.arb); API generator [tool/gen_l10n.dart](../../../tool/gen_l10n.dart); runtime [lib/l10n/runtime/](../../../lib/l10n/runtime/).
- Wiring: `MaterialApp` in [lib/main.dart](../../../lib/main.dart).
- Translations: hand `app_en.arb` (values + descriptions) to any general model, keep `{placeholder}` tokens, save as `app_<locale>.arb`. No script or credential.
- Guards: [test/js/l10n_no_hardcoded_text.test.js](../../../test/js/l10n_no_hardcoded_text.test.js), [test/js/l10n_coverage.test.js](../../../test/js/l10n_coverage.test.js).
- First migrated screen: [lib/screens/trusted_certificates.dart](../../../lib/screens/trusted_certificates.dart).
- The guard's display-sink list is the contract; custom widgets taking a raw
  `String label` are not covered. Prefer passing localized strings into such
  widgets at the call site, which the call-site file's own guard enforces once
  migrated.
