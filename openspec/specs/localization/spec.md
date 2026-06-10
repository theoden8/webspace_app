# UI Localization

## Status
**Partially implemented** (infrastructure + guard + first migrated screen; remaining screens tracked as migration tasks)

## Purpose

Make every user-facing string in the app translatable, with English as the
authored source of truth, and guarantee no screen ever shows text that is not
backed by a translation key. Translations are produced by an LLM "fill"
runner rather than a hosted translation platform (issue #406): no closed-source
dependency, no human-coordination overhead.

## Problem Statement

UI strings were hardcoded English literals scattered across `lib/main.dart`,
`lib/screens/`, and `lib/widgets/` (~520 `Text(` widgets). There was no
localization infrastructure (`generate: true` in pubspec belonged to
`flutter_launcher_icons`; the README's "30+ languages" is per-site
`Accept-Language` spoofing, not UI translation). A localization effort needs:

- a single English source of truth that survives review,
- machine translation that does not require organizing translators,
- a coverage signal so a half-translated locale cannot ship blank strings,
- enforcement that new code does not reintroduce hardcoded strings.

## Solution

Standard Flutter `gen_l10n`: ARB files under `lib/l10n/`, with `app_en.arb` as
the template and code generated into `lib/l10n/gen/` (gitignored; regenerated
by `generate: true`). The `MaterialApp` wires `AppLocalizations` delegates and
`supportedLocales`. Locale ARBs are filled by `tool/translate_arb.dart` against
an OpenAI-compatible endpoint. Coverage is enforced in CI by Dart tests, not by
the translation tool. Migration is phased behind a guard whose enforced scope
only grows.

---

## Requirements

### Requirement: LOC-001 - ARB source of truth

The English ARB SHALL be the single authored source of all UI strings, and
generated localization code SHALL NOT be committed.

#### Scenario: English template drives generation

- **Given** `lib/l10n/app_en.arb` with `@@locale: "en"` and one entry per UI string
- **And** `l10n.yaml` setting `template-arb-file: app_en.arb`, `output-dir: lib/l10n/gen`
- **When** `flutter gen-l10n` (or any build, via `generate: true`) runs
- **Then** `AppLocalizations` is produced under `lib/l10n/gen/`
- **And** that directory is gitignored, reproducible by one command from a clean clone

#### Scenario: Every key is documented

- **Given** a message key `k` in the template
- **Then** a sibling `@k` block exists with a non-empty `description`
- **And** `test/l10n_coverage_test.dart` fails if any key lacks it

### Requirement: LOC-002 - No unkeyed user-facing text

A migrated UI file SHALL NOT pass a raw string literal into a user-facing
display sink; all on-screen text SHALL resolve through `AppLocalizations`.

#### Scenario: Hardcoded literal in a migrated file fails the build

- **Given** a file listed in `migrated` in `test/l10n_no_hardcoded_text_test.dart`
- **When** it contains a literal opening a display sink (`Text(`, `SelectableText(`, `Tooltip(`, or `tooltip:`/`hintText:`/`labelText:`/`helperText:`/`errorText:`/`counterText:`/`prefixText:`/`suffixText:`/`semanticLabel:`)
- **Then** the guard test fails, naming the file and line
- **And** pure-data display (e.g. `host:port`) is extracted to a local variable so no literal sits inside a display widget

#### Scenario: New UI file cannot slip past the guard

- **Given** a new `.dart` file under `lib/main.dart`, `lib/screens/`, or `lib/widgets/`
- **When** it is in neither the `migrated` nor `pending` list
- **Then** the guard test fails, requiring it be classified

### Requirement: LOC-003 - Translation coverage gate

Every non-template locale ARB SHALL define exactly the template's keys, with
matching placeholder tokens and no empty values.

#### Scenario: Missing or empty translation fails CI

- **Given** a locale ARB `app_<x>.arb`
- **When** it omits a template key, or has an empty value
- **Then** `test/l10n_coverage_test.dart` fails

#### Scenario: Placeholder drift fails CI

- **Given** a template string `"... {host}:{port} ..."`
- **When** the locale translation drops or renames a `{token}`
- **Then** the coverage test fails (interpolation would break)

#### Scenario: gen-l10n untranslated report is empty

- **Given** `untranslated-messages-file: l10n_untranslated.json` in `l10n.yaml`
- **When** the report exists after generation
- **Then** it is `{}` (no untranslated messages) or the coverage test fails

### Requirement: LOC-004 - LLM fill runner

Locale ARBs SHALL be fillable by `tool/translate_arb.dart` from the English
template, additively and without overwriting existing values.

#### Scenario: Fill only missing keys

- **Given** `app_de.arb` missing some template keys
- **When** `dart run tool/translate_arb.dart de` runs with `WEBSPACE_TRANSLATE_API_KEY` set
- **Then** only missing/empty keys are translated and merged
- **And** existing (human-corrected) values are preserved
- **And** placeholder tokens are instructed to be preserved verbatim

#### Scenario: Provider is configurable

- **Given** `WEBSPACE_TRANSLATE_BASE_URL` / `WEBSPACE_TRANSLATE_MODEL`
- **Then** any OpenAI-compatible chat-completions endpoint can be used, with no closed-source platform dependency

### Requirement: LOC-005 - Phased migration

String migration SHALL proceed file-by-file, with the guard's enforced set
only growing.

#### Scenario: Migrating a file

- **Given** a file in `pending`
- **When** all its strings are routed through `AppLocalizations` and keys added to `app_en.arb`
- **Then** it is moved from `pending` to `migrated`
- **And** the migration is complete when `pending` is empty

### Requirement: LOC-006 - MaterialApp wiring

The root `MaterialApp` SHALL register the localization delegates and supported
locales.

#### Scenario: Delegates registered

- **Given** the root `MaterialApp`
- **Then** `localizationsDelegates: AppLocalizations.localizationsDelegates`
- **And** `supportedLocales: AppLocalizations.supportedLocales`
- **And** the OS window title resolves via `onGenerateTitle` -> `appTitle`

---

## Implementation Notes

- Config: [l10n.yaml](../../../l10n.yaml), template [lib/l10n/app_en.arb](../../../lib/l10n/app_en.arb).
- Wiring: `MaterialApp` in [lib/main.dart](../../../lib/main.dart).
- Runner: [tool/translate_arb.dart](../../../tool/translate_arb.dart).
- Guards: [test/l10n_no_hardcoded_text_test.dart](../../../test/l10n_no_hardcoded_text_test.dart), [test/l10n_coverage_test.dart](../../../test/l10n_coverage_test.dart).
- First migrated screen: [lib/screens/trusted_certificates.dart](../../../lib/screens/trusted_certificates.dart).
- The guard's display-sink list is the contract; custom widgets taking a raw
  `String label` are not covered. Prefer passing localized strings into such
  widgets at the call site, which the call-site file's own guard enforces once
  migrated.
