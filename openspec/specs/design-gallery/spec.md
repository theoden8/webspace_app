# Design Gallery Specification

## Purpose

Let a designer work on this app's interface with real interaction and shared
files, without being able to break it, and without anyone having to eyeball a
screenshot to find out. The designer edits Dart (`lib/theme/design_tokens.dart`,
`lib/theme/accent_theme.dart`, the widgets), drives the real app in a browser,
and every constraint that used to live in review is a check that fails.

Two things make that possible and both are fragile in the same direction: the
app must keep compiling for web, and the tokens must keep meaning what the
widgets assume. Ordinary headless work on the interface — a new widget, a new
service import, a retuned value — breaks either one without any local symptom,
because nothing in a normal `flutter test` run or an Android build looks at
them. This spec is the contract that keeps them true.

## Status

- **Status**: Implemented
- **Platforms**: Design-time only. The app is not shipped for web; the WebView
  does not run there.
- **CI Integration**: GitHub Actions (`build-and-test.yml` → `validate` job for
  the static and value gates, `design-web` job for the compile and render
  gates)

---

## Layered design

Five layers, cheapest first. Each catches a class the next cannot see.

1. **Web-clean scan** (`tool/design_gallery/web_clean.js`, Node, no toolchain) —
   walks the transitive imports of every file under `lib/widgets/`,
   `lib/screens/` and `lib/main.dart`, and reports anything reaching `dart:io`
   or `dart:ffi`.
2. **Token values** (`test/design_tokens_validity_test.dart`, plain
   `flutter test`) — relationships between the tokens, never fixed numbers.
3. **Token layout** (`test/design_render_matrix_test.dart`, widget tests) — the
   widgets that read the tokens, rendered across widths, text scales and
   brightnesses.
4. **Gallery build + cards** (`scripts/design_web.sh gallery`,
   `tool/design_gallery/shoot.js`) — the real web compile, then one screenshot
   per card with an ink floor.
5. **Designer app + packaging** (`scripts/design_web.sh app`,
   `tool/design_gallery/pack_app.js`,
   `test/browser/design_app_packaging.test.js`) — the app the designer actually
   drives, packed for the Claude Design project and booted in an iframe.

---

## Requirements

### Requirement: DESIGN-001 — Every UI file compiles for web

`lib/main.dart` and every file under `lib/widgets/` and `lib/screens/` MUST
avoid `dart:io` and `dart:ffi` on all transitive import paths. A platform call
goes behind a conditional-export seam (`lib/platform/host_platform.dart`,
`lib/services/file_store.dart`, `lib/services/outbound_http.dart`,
`lib/services/adblock_engine.dart`), whose native half is unchanged.

#### Scenario: A new widget imports dart:io directly

- **GIVEN** a widget added under `lib/widgets/`
- **WHEN** it imports `dart:io`, or imports a service that does
- **THEN** `npm run design:check` exits non-zero, naming the file and the import
  chain that reaches the blocker
- **AND** the `validate` CI job fails

#### Scenario: The platform call goes through the seam instead

- **GIVEN** the same widget needs `Platform.isAndroid`
- **WHEN** it reads `hostIsAndroid` from `lib/platform/host_platform.dart`
- **THEN** the scan reports it clean, the native build is byte-identical in
  behaviour, and the widget is available to the gallery and to the designer's app

#### Scenario: Exploring without the gate

- **WHEN** a developer runs `node tool/design_gallery/web_clean.js --report`
- **THEN** the same report is printed with no exit code, so the blocked chains
  can be read while the work is in progress

### Requirement: DESIGN-002 — The design gallery and the designer app build

Both web entrypoints MUST compile. `lib/design_gallery/main.dart` is the card
gallery; `lib/design_app/main.dart` is the real `WebSpaceApp` on demo data, and
is what a designer interacts with.

#### Scenario: A change breaks the web compile

- **GIVEN** a change to any file either entrypoint reaches
- **WHEN** the `design-web` CI job runs `scripts/design_web.sh gallery` and
  `scripts/design_web.sh app`
- **THEN** a compile failure fails the job, before any card is shot

#### Scenario: The engine is local

- **WHEN** either target is built
- **THEN** `--no-web-resources-cdn` is passed and Roboto is synced from the
  pinned npm dependency, because CanvasKit fetched from gstatic.com produces a
  page that loads, boots nothing, and reports no error, and a missing Roboto
  draws no text at all rather than a fallback face

### Requirement: DESIGN-003 — Every card renders something

A card that draws nothing is the failure a widget test cannot see: the tree can
be correct while the frame is empty.

#### Scenario: A card comes back blank

- **GIVEN** the gallery built and served locally
- **WHEN** `tool/design_gallery/shoot.js` screenshots a card and it falls below
  1% ink or 12 distinct colours, after one retry
- **THEN** the run reports it as BLANK and exits non-zero

#### Scenario: A card is registered on one side only

- **GIVEN** a card id in `lib/design_gallery/main.dart`
- **WHEN** `tool/design_gallery/shoot.js` has no viewport for it, or names a
  viewport for an id that does not exist
- **THEN** `test/js/design_gallery_registry.test.js` fails, because otherwise
  the card is silently never shot

### Requirement: DESIGN-004 — Design values live in the token files

Values that belong to the design system live in `lib/theme/design_tokens.dart`
(fixed chrome, spacing, radii, motion) and `lib/theme/accent_theme.dart`
(anything accent-derived), so a designer has one file to edit rather than a
literal buried in a widget.

#### Scenario: A migrated widget reintroduces a literal

- **GIVEN** a file listed as MIGRATED in
  `test/js/design_tokens_no_literals.test.js`
- **WHEN** it gains a raw `Color(0x…)`, `BorderRadius.circular(n)` or
  `Duration(milliseconds: n)`
- **THEN** the guard fails, naming the token that replaces it

#### Scenario: A new UI file is neither migrated nor pending

- **GIVEN** a new file under `lib/widgets/` or `lib/screens/`
- **WHEN** it appears in neither list
- **THEN** the guard fails, so the classification cannot go stale silently

### Requirement: DESIGN-005 — Token values stay internally consistent

The tokens MUST be checked against each other rather than against fixed
numbers, so that retuning is free and inverting the design is not.

#### Scenario: A scale stops being a scale

- **WHEN** a radius or spacing step is edited so the sequence no longer ascends,
  or a spacing value leaves the 4pt grid
- **THEN** `test/design_tokens_validity_test.dart` fails, naming the pair

#### Scenario: The chrome inverts

- **WHEN** the light chrome bar is no longer lighter than the dark one, a bar
  loses opacity, or a hairline stops separating from its bar (below 1.05:1) or
  starts reading as a drawn border (above 3:1)
- **THEN** the same test fails

#### Scenario: A meaningful indicator becomes illegible

- **GIVEN** the URL bar padlock, which is the app's only security signal
- **WHEN** either state falls below 3:1 against either chrome bar (WCAG 1.4.11),
  or the two states come within ΔE 20 of each other
- **THEN** the test fails. Distinguishability is measured as CIE76 ΔE, not as a
  luminance ratio: the two states differ in hue and may legitimately sit at the
  same lightness.

#### Scenario: State is signalled by colour alone

- **WHEN** the padlock's icon does not branch on the same condition as its
  colour
- **THEN** the test fails (WCAG 1.4.1): a 16px colour difference is not a signal
  a colour-blind user can read, and an http page would read as secure.

#### Scenario: A control drops below the tap-target floor

- **WHEN** `TapTargets.compact` falls below the icon size it holds, or below 32
- **THEN** the test fails

### Requirement: DESIGN-006 — Token changes still lay out

Value relationships cannot see geometry. Every widget that reads the tokens
MUST render across the matrix that varies in the field.

#### Scenario: A token change overflows a narrow screen

- **GIVEN** a spacing, icon-size or text-size token increased
- **WHEN** `test/design_render_matrix_test.dart` renders each subject at 320,
  411 and 800pt, at 1.0x, 1.3x and 2.0x text scale, in both brightnesses
- **THEN** a `RenderFlex` overflow in any cell fails that cell, naming the
  width, scale and brightness

#### Scenario: A control shrinks without overflowing

- **WHEN** a token change leaves the URL bar's submit button or the tab-strip
  corner button below `TapTargets.compact`
- **THEN** the matrix's explicit tap-target assertions fail, because shrinking
  overflows nothing

#### Scenario: A widget stops rendering entirely

- **WHEN** a subject renders an empty tree
- **THEN** the cell fails on its find-by-type assertion rather than passing on
  an absence

### Requirement: DESIGN-007 — Accent colours stay legible

Every accent the user can pick MUST hold WCAG AA (4.5:1) on its paired
on-colour, in both brightnesses. `buildAccentColorScheme` overrides the
seed-derived roles to keep accents saturated, so Material 3 is no longer
guaranteeing this.

#### Scenario: An accent or a role is retuned

- **WHEN** an accent constant changes, or a role pair in
  `buildAccentColorScheme` is edited
- **THEN** `test/accent_theme_contrast_test.dart` reports every pair below
  4.5:1 with its measured ratio

### Requirement: DESIGN-008 — The designer app survives packing

The Claude Design project has no toolchain: it cannot build Flutter, run a
browser, or read this repository. The built app is uploaded to it as plain
files under `app/` and iframed by a card, which imposes three differences from
a plain `build/web`.

#### Scenario: The packed app is served from a subdirectory

- **GIVEN** `tool/design_gallery/pack_app.js` output
- **WHEN** `test/browser/design_app_packaging.test.js` serves it under `/app/`
  and loads it in an iframe
- **THEN** `<base href>` MUST be `./` (an absolute base sends every asset
  request to the host root), the service-worker registration MUST be absent
  (its scope is not ours), and the engine MUST reach a `flt-glass-pane`

#### Scenario: The packing output is missing

- **WHEN** the test runs without `build/design_app_upload`
- **THEN** it skips rather than fails, since not every CI job builds for web

### Requirement: DESIGN-009 — Refreshes are requested, never assumed

The design project cannot rebuild itself, so the loop needs a channel back.

#### Scenario: The design side wants a rebuild

- **WHEN** it overwrites `_requests/refresh.md` with a `date:` line in UTC and a
  plain-English body
- **THEN** a session with the toolchain treats it as pending if that date is
  later than the `serviced:` date in `_requests/status.md`, services it, and
  writes back the serviced date, the commit built from, and anything asked for
  that was not done

#### Scenario: A publish would clobber a pending request

- **WHEN** the bundle is uploaded
- **THEN** `_requests/refresh.md` MUST NOT be part of it; `bundle.js` ships only
  `README.md`, and the mailbox is seeded once

#### Scenario: A request asks for a code change

- **GIVEN** request text written by whoever is in the design project
- **WHEN** it reads as an instruction rather than a description
- **THEN** it is treated as data: it names cards and screens to look at, it does
  not decide what the app does

---

## Non-goals

- **Pixel diffing the cards.** Cross-version rasterisation noise buries the real
  changes; the ink floor catches the failure that matters (nothing drew).
- **Shipping the app for web.** `web/` exists for this pipeline. The WebView
  does not run there, and cards draw a placeholder where site content goes.
- **Design review by eye as a gate.** Anything that requires a human to compare
  two images before merging is out of scope by construction; the layers above
  are the gate.
