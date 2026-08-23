# Settings Hints

## ADDED Requirements

### Requirement: HINT-001 — State on the row, explanation behind the hint

A settings row has three places text can go, and each one MUST carry a
different kind of text:

- **Title** — what the setting is.
- **Subtitle** — what the setting currently *is set to*, or a status that
  changes with the world: a value, a count, `Not configured`, `System`,
  `Forced off by Tracking Protection`. It MAY be absent.
- **Hint dialog** — what the setting does, what it costs, when to want it.
  Reached by a `HintButton` ([lib/widgets/hint_button.dart](../../../../../lib/widgets/hint_button.dart))
  sitting next to the title, and free to run as long as the explanation needs.

A row MAY keep a short fixed caption in its subtitle where that caption is what
makes the list scannable, subject to HINT-002. What it MUST NOT do is put the
explanation there: a dialog costs one icon of layout whatever it says, and a
subtitle costs every character of it, in every language, on every visit.

The label sharing the title row with a `HintButton` MUST be `Flexible` so it
wraps rather than overflowing — the separate concern gated by
`test/js/settings_title_row_overflow.test.js`.

#### Scenario: A new toggle needs explaining

- **GIVEN** a setting whose effect is not obvious from its title
- **WHEN** the row is built
- **THEN** the explanation goes in a `HintButton` on the title row
- **AND** the subtitle is either absent or names the setting's current state

#### Scenario: A row already reports state

- **GIVEN** a blocker row whose subtitle reads `Not configured` until its data
  is downloaded, then reports a rule count
- **WHEN** the row is built
- **THEN** that subtitle stays: it is the one fact the row cannot express any
  other way, and its length tracks the state, not a translator's word choice

#### Scenario: The hint already says it

- **GIVEN** a row that carries both a `HintButton` and a fixed subtitle
- **WHEN** the hint body already covers what the subtitle says
- **THEN** the subtitle is dropped and its ARB key deleted from every locale,
  rather than kept as a shorter restatement of the dialog

### Requirement: HINT-002 — A fixed-string subtitle stays within the row's budget

A `subtitle:` whose text is a single fixed localized string — one uninvoked
`loc.<key>`, no branch — MUST be at most **90 characters in every shipped
locale**, roughly two lines under a switch at the narrowest supported width.
Over that, the string is an explanation and MUST move into the row's hint.

The budget is a proxy for width, not a measurement of it: scripts differ in how
much room a character takes, and the number exists to catch the paragraph, not
to police the last character.

Subtitles built from state are exempt, and are recognised structurally: a
subtitle expression with no `loc.` reference, more than one, an invoked one
(`loc.key(count)`), or a `?`/`switch` choosing between alternatives is
state-derived by construction.

Gate: `test/js/settings_hint_placement.test.js`, scanning `lib/main.dart`,
`lib/screens/` and `lib/widgets/` against every `lib/l10n/app_*.arb`. It runs
under `npm run test:js` in CI's `validate` job.

#### Scenario: An English one-liner triples in another language

- **GIVEN** a subtitle of 61 characters in English
- **WHEN** its Spanish translation reaches 92
- **THEN** the gate fails, naming the file, line, key, worst locale and length
- **AND** the fix is to move the string into a `HintButton`, never to shorten
  the translation

#### Scenario: A state-derived subtitle is left alone

- **GIVEN** `subtitle: Text(enabled ? loc.on : loc.off)` or
  `subtitle: Text(loc.rulesCount(n))`
- **WHEN** the gate runs
- **THEN** neither is reported, whatever the strings' length

#### Scenario: A new locale pushes a passing string over

- **GIVEN** a subtitle currently inside the budget in all 68 locales
- **WHEN** a 69th locale translates it to 95 characters
- **THEN** the gate fails on that locale, and the row moves its description
  into a hint — the string was already near the edge in the languages that
  ship

#### Scenario: The extractor breaks

- **WHEN** the scan finds fewer than ten fixed-string subtitles, or fewer than
  ten locales
- **THEN** the gate fails rather than passing on an empty result, because a
  regex that silently matches nothing reads exactly like a clean repository

### Requirement: HINT-003 — A description that moves stays reachable and stays translated

Moving an explanation off the row MUST NOT lose it and MUST NOT lose its 68
translations.

- The ARB key is **renamed in place** (`<setting>Subtitle` → `<setting>Hint`)
  across every `lib/l10n/app_*.arb`, keeping each locale's existing value; its
  `@`-block description in `app_en.arb` is reworded to say it is now a hint
  body.
- The key is **deleted** from every locale only when an existing hint on the
  same row already says what it said (HINT-001).
- The `HintButton`'s `title` is the row's own title, so the dialog names the
  setting the user tapped.

Retranslating is not required and not implied: the sentence that was accurate
on the row is accurate in the dialog.

#### Scenario: A description moves into a new hint

- **GIVEN** `appSettingsBackOpensMenuSubtitle`, translated into 68 locales
- **WHEN** the row's description moves behind a hint button
- **THEN** the key becomes `appSettingsBackOpensMenuHint` in all 68 files with
  every translation intact
- **AND** `test/js/l10n_coverage.test.js` still reports full key parity
- **AND** the row renders as title + info icon, with no subtitle

#### Scenario: A description is redundant and goes away

- **GIVEN** `siteSettingsHtmlCachingSubtitle` on a row that already has
  `siteSettingsHtmlCachingHint`, whose body covers the same ground
- **WHEN** the row is cleaned up
- **THEN** the subtitle key is removed from all 68 locales and the row keeps
  only its existing hint
