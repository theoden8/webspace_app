## 1. Specify

- [x] 1.1 Write `specs/app-settings/spec.md` with APPSET-001 (the index),
  APPSET-002 (row summaries), APPSET-003 (category screens) and APPSET-004
  (one tap, one action).
- [x] 1.2 Add the `app-settings` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until the change is archived.

## 2. Split the screen

- [x] 2.1 Move each group's rows, state and handlers into its own screen file;
  shared rows into `lib/widgets/settings_rows.dart`.
- [x] 2.2 Keep `AppSettingsScreen`'s constructor; the index copies what the
  categories change and keeps the summaries current through their callbacks.
- [x] 2.3 Backup returns the chosen action; the index closes settings and runs
  it, as the single list did.

## 3. Races

- [x] 3.1 `SettingsOpenGuard` on every opener; route checks on the Backup
  choice and the developer-mode switch; coalesced proxy saves; one discard
  prompt.

## 4. Strings

- [x] 4.1 Add the category titles and group headings to `app_en.arb`; drop
  `appSettingsInterface` and `appSettingsManageScripts`.
- [x] 4.2 The same in the other 66 locales, in their own commit.

## 5. Gate it

- [x] 5.1 `test/app_settings_index_test.dart`: order, nothing inline, summary
  shapes, write-through, Backup's close-then-run, the Developer row, and the
  double-tap cases.
- [x] 5.2 Route the existing App Settings tests through the category rows.
- [x] 5.3 Classify the new files in the l10n and design-token gates.
- [x] 5.4 Gallery cards for each category screen (registry and `shoot.js`).
