## 1. Specify

- [x] 1.1 Write `openspec/changes/site-behaviour/specs/site-behaviour/spec.md`
  with BEHAV-001 (the screen, its two groups, the incognito forcing, the
  no-persistent-state contract) and BEHAV-002 (row placement and summary).
- [x] 1.2 Modify ETP-017 where it places the rows: HTML caching now lives on
  the Behaviour screen, and the "Site" heading holds three rows.
- [x] 1.3 Add the `site-behaviour` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until the change is archived.

## 2. Build the screen

- [x] 2.1 Add `lib/screens/site_behaviour.dart`: `SiteBehaviourValues` (six
  booleans, `copyWith`, `effectiveAlwaysOpenHome`) and `SiteBehaviourScreen`,
  modelled on `SitePrivacyScreen` — value in, whole values out, no state of
  its own.
- [x] 2.2 Group the rows: "Opening and display" (Always open Home, Kiosk mode,
  Full screen mode, HTML caching) and "Link handling" (Block auto-redirects,
  Open external links in browser, the claims editor slot).
- [x] 2.3 Take the domain-claim editor as a widget from the caller rather than
  the model: it writes straight to the model, so it stays where the model is.

## 3. Wire it into site settings

- [x] 3.1 Replace the inline behaviour block in `lib/screens/settings.dart`
  with `_buildBehaviourRow` + `_openBehaviour`, keeping the fields, the
  snapshot diff and the save path where they are.
- [x] 3.2 Put the row under the "Site" heading ahead of Privacy and
  Permissions, with a summary that names what is on.

## 4. Strings

- [x] 4.1 Rename `siteSettingsSectionBehaviour` to `behaviourTitle` in all 68
  `lib/l10n/app_*.arb`, keeping every translation.
- [x] 4.2 Add `behaviourGroupOpening` and `behaviourSummaryNothingOn` in all 68
  locales; reuse `linkHandlingScreenTitle` for the link group.

## 5. Gate it

- [x] 5.1 Add `test/site_behaviour_screen_test.dart`: every switch present and
  interactive, the incognito forcing, whole-value reporting, and the claims
  editor rendering below the switch whose hint names it.
- [x] 5.2 Classify `lib/screens/site_behaviour.dart` in
  `test/js/l10n_no_hardcoded_text.test.js` (migrated) and
  `test/js/design_tokens_no_literals.test.js` (pending, like its siblings).
