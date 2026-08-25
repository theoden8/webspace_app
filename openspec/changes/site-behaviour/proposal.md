## Why

Site settings sends two of its four groups to screens of their own. Privacy
(eight switches) and Permissions (seven capabilities) each became one row with
a summary, because a reader opens them deliberately and wants the whole topic
in one place. Behaviour did not: its six switches plus the domain-claim editor
stayed inline, in the middle of the list, between the content controls above
and the proxy fields below.

So the settings screen still opens onto a wall — javascript, a user-agent field
with its identity readout, a language dropdown, a zoom slider, a user-scripts
row, then six unrelated switches and a claims editor, then five proxy fields —
before reaching the two rows that were extracted precisely because a reader
looks for them by name. The switches that got pulled out were not the long
ones; they were the ones that belong together.

Behaviour is the same kind of group: one topic (how the app hosts the site),
seven controls, none of which anyone edits on the way to something else. Two of
them already cross-reference each other — the external-links hint tells the
reader to add domains "under Domain claims below" — which is the shape of a
screen, not of a stretch of a longer list.

## What Changes

- **A Behaviour screen.** New `SiteBehaviourScreen`
  ([lib/screens/site_behaviour.dart](../../../lib/screens/site_behaviour.dart)),
  built like its two siblings: a value object in, whole values out through
  `onChanged`, no persistent state of its own. Two groups — "Opening and
  display" (Always open Home, Kiosk mode, Full screen mode, HTML caching) and
  "Link handling" (Block auto-redirects, Open external links in browser, the
  domain-claim editor).
- **A third row under "Site".** Behaviour, Privacy, Permissions, in that order,
  each summarising its state without being opened. The Behaviour summary names
  the switches that are on (at most two, then a "{count} more" overflow), or
  reads "Nothing enabled".
- **Nothing else moves.** No setting is added, removed, defaulted differently
  or re-scoped; the dirty-snapshot diff, the save path and the domain-claim
  write path are the ones that were already there.
- ETP-017's two sentences that place these rows are updated: HTML caching now
  lives on the Behaviour screen rather than "with the other behaviour switches
  on the settings screen", and the "Site" heading now holds three rows.

## Impact

- New: `lib/screens/site_behaviour.dart`, `test/site_behaviour_screen_test.dart`.
- `lib/screens/settings.dart`: the behaviour block becomes `_buildBehaviourRow`
  + `_openBehaviour`.
- `lib/l10n/app_*.arb` (68 files): `siteSettingsSectionBehaviour` renamed to
  `behaviourTitle` keeping every translation (it is now a screen title, not a
  section heading); two keys added, `behaviourGroupOpening` and
  `behaviourSummaryNothingOn`. The link group reuses `linkHandlingScreenTitle`.
- Spec: new capability `site-behaviour`; `tracking-protection`'s ETP-017
  modified where it places the rows.
