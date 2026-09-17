## Why

Settings rows explain themselves two different ways. Most carry a `HintButton`
on the title row: an info icon that opens a dialog, costing one line of layout
no matter how much it says. A handful instead put the explanation in the tile's
`subtitle`, where every character is on screen forever.

That second form reads fine in English and falls apart everywhere else.
"Back gesture opens the menu" carries a 155-character English subtitle; the
Malay and Greek translations run to 196, which is four wrapped lines under a
switch. "Full screen on shortcut launch" goes from 61 to 92 characters in
Spanish, "Tab Width Limit" from 59 to 100 in Armenian. Nothing overflows, so
no render test sees it — the list just turns ragged, with some rows one line
tall and others four.

Two of those rows already have a hint button *and* a long subtitle saying a
subset of the same thing, so the prose on the row is not even buying
information.

There was no rule saying which form to use, so which one a row got was down to
whoever added it.

## What Changes

- **A convention, specified.** A settings row's subtitle reports the setting's
  *state*; anything that explains the setting goes in the row's `HintButton`.
  New capability spec `settings-hints` (HINT-001..HINT-003).
- **A gate.** `test/js/settings_hint_placement.test.js` reads every `subtitle:`
  in `lib/main.dart`, `lib/screens/` and `lib/widgets/`, keeps the ones whose
  text is a single fixed localized string, and fails when that string exceeds
  90 characters in any of the 68 shipped locales. State-derived subtitles are
  exempt.
- **The five rows that were over.** Three move their description into a new
  hint button (`Full screen on shortcut launch`, `Back gesture opens the menu`,
  `Tab Width Limit`); two drop a subtitle their existing hint already
  subsumes (`Open External Links in Browser`, `HTML Caching`).

## Measured effect

Row heights from a widget test pumping `AppSettingsScreen` at 360dp, before and
after. The absolute numbers come from the test environment's placeholder font,
which is wider than any real face — read the ratio, not the pixels. `Stats Bar`
keeps its subtitle and is the control.

| Row | locale | before | after |
|---|---|---|---|
| Back gesture opens the menu | el | 412 | 136 |
| Back gesture opens the menu | ms | 368 | 136 |
| Back gesture opens the menu | hy | 308 | 88 |
| Back gesture opens the menu | en | 264 | 112 |
| Full screen on shortcut launch | es | 232 | 136 |
| Full screen on shortcut launch | en | 188 | 88 |
| Tab Width Limit | el | 168 | 96 |
| Tab Width Limit | es | 152 | 108 |
| Stats Bar (control) | any | unchanged | unchanged |

## Impact

- `lib/screens/app_settings.dart`, `lib/screens/settings.dart`
- `lib/l10n/app_*.arb` (68 files): three `…Subtitle` keys renamed to `…Hint`
  keeping their translations, two deleted as redundant with an existing hint.
- New: `test/js/settings_hint_placement.test.js` (runs in `npm run test:js`,
  CI's `validate` job).
- No behaviour change beyond layout: no setting gains, loses, or changes
  meaning, and no string is retranslated.
