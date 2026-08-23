## 1. Specify the convention

- [x] 1.1 Write `openspec/changes/settings-hints/specs/settings-hints/spec.md`
  with HINT-001 (state on the row, explanation behind the hint), HINT-002 (the
  fixed-string subtitle budget) and HINT-003 (a moved description keeps its
  translations).
- [x] 1.2 Add the `settings-hints` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until the change is archived.
- [x] 1.3 Add a CLAUDE.md section telling the next person which of the three
  places a new settings string goes in.

## 2. Gate it

- [x] 2.1 Add `test/js/settings_hint_placement.test.js`: read every `subtitle:`
  argument under `lib/main.dart`, `lib/screens/` and `lib/widgets/` with a
  bracket-and-quote-aware scanner, keep the ones naming a single uninvoked
  `loc.<key>` with no branch, and fail when that key exceeds 90 characters in
  any `lib/l10n/app_*.arb`.
- [x] 2.2 Report file, line, key, worst locale and length, and say in the
  failure message that the fix is a `HintButton`, not a shorter translation.
- [x] 2.3 Guard the extractor itself: fail when the scan finds fewer than ten
  fixed-string subtitles or fewer than ten locales, so a broken regex cannot
  pass as a clean repository.
- [x] 2.4 Confirm the gate catches a regression — re-add a long subtitle to the
  HTML caching row and check the run fails naming it.

## 3. Move the five rows that were over budget

- [x] 3.1 `Full screen on shortcut launch` (`lib/screens/app_settings.dart`):
  title becomes `Row([Flexible(Text), HintButton])`, subtitle dropped.
- [x] 3.2 `Back gesture opens the menu`: same, 196 characters in `ms` off the
  row.
- [x] 3.3 `Tab Width Limit`: the free-floating caption under the slider becomes
  a hint on the slider's label row; the row keeps its `NNN px` value readout.
- [x] 3.4 `Open External Links in Browser` (`lib/screens/settings.dart`): drop
  the subtitle, whose content the existing hint already states.
- [x] 3.5 `HTML Caching`: same.

## 4. Migrate the strings

- [x] 4.1 Rename `appSettingsFullscreenOnShortcutSubtitle`,
  `appSettingsBackOpensMenuSubtitle` and `appSettingsTabMaxWidthSubtitle` to
  `…Hint` across all 68 `lib/l10n/app_*.arb`, keeping every translation.
- [x] 4.2 Reword those three `@`-block descriptions in `app_en.arb` to say the
  string is a hint dialog body.
- [x] 4.3 Delete `siteSettingsExternalLinksInBrowserSubtitle` and
  `siteSettingsHtmlCachingSubtitle` from all 68 locales.

## 5. Verify

- [x] 5.1 `npm run test:js` — 488 pass, including the new gate,
  `l10n_coverage` key parity and `settings_title_row_overflow`.
- [x] 5.2 `flutter analyze` — no new errors.
- [x] 5.3 `flutter test` — 2371 pass.
- [x] 5.4 `npx openspec validate --no-interactive --all`.
