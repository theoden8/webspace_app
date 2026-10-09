## Why

App Settings was one screen of about four phone screens: nine headings, three
text fields, two sliders, a list of filter lists that grows with every custom
list, and several rows under the wrong heading. HTTPS upgrade, the protection
report and the stats bar sat under "Interface"; the location picker's map
tiles and the timezone dataset sat under "Outbound proxy"; the Firefox version
used by generated user agents sat under "Privacy"; trusted certificates sat
under "Privacy" rather than with the connection they decide.

Site settings solved the same problem by sending its groups to screens of
their own (BEHAV-001, NET-001): one row each, with a summary that answers the
common question without opening it. App Settings is the same kind of surface
and gets the same treatment.

## What Changes

- **An index.** `AppSettingsScreen` becomes a list of category rows under four
  headings: "App" (Appearance, Behaviour), "Every site" (Network, Privacy, User
  scripts), "Data" (Backup and archives) and "About" (App logs or Developer,
  Licenses, Version). No setting is edited on it.
- **Seven category screens**, one file each: `AppAppearanceScreen` (language,
  theme, accent), `AppBehaviourScreen` (tab strip, full screen, back gesture,
  link handling, search), `AppNetworkScreen` (app-wide proxy, saved proxies,
  Tor status, trusted certificates), `AppPrivacyScreen` (protection report,
  stats bar, trackers and ads, what sites learn, screen capture),
  `ContentBlockerSettingsScreen` (opened from Privacy), `AppBackupScreen` and
  `AppDeveloperScreen`.
- **Rows that were filed wrongly move** with the split: HTTPS upgrade, the
  report and the stats bar to Privacy; the Firefox version, the timezone
  dataset and the map tiles to Privacy's "What sites learn" group (they decide
  what a site is told, which is what Privacy covers per BEHAV-001); trusted
  certificates to Network.
- **Developer is a row only in developer mode**, in the About group beside the
  Version row whose taps turn it on. Otherwise the app logs are linked
  directly, as before.
- **Each row says what its category is set to**, with the BEHAV-002 rule: the
  names of what is on, at most two, then "{count} more".
- **One tap, one action.** Every row that opens a screen or a dialog drops a
  second tap while the first is still opening or what it opened is on top;
  the Backup screen and the developer-mode switch cannot pop past their own
  screen; the app-wide proxy saves one at a time; Back pressed twice raises
  one discard prompt.
- Nothing else changes. No setting is added, removed, re-defaulted or
  re-scoped, and every setting still applies the moment it changes. The DNS
  blocklist download now re-attaches webviews even when its screen was left
  mid-download, which leaving the old single screen also skipped.

## Impact

- New: `lib/screens/app_appearance.dart`, `app_behaviour.dart`,
  `app_network.dart`, `app_privacy.dart`, `content_blocker_settings.dart`,
  `app_backup.dart`, `app_developer.dart`; `lib/widgets/settings_rows.dart`
  (group header, category row, summary rule, open guard);
  `test/app_settings_index_test.dart`.
- `lib/screens/app_settings.dart`: the index. Its constructor is unchanged, so
  `main.dart` and the design gallery's existing card build it as before.
- Strings: ten keys added (category titles and group headings); `Interface`
  and `Manage Scripts` dropped, nothing references them.
- Tests that walked the single list open the category first:
  `app_settings_experimental_test.dart`,
  `app_settings_timezone_dataset_test.dart`,
  `developer_mode_unlock_widget_test.dart`, `web_search_entry_test.dart`, and
  the two settings integration tests.
- Design gallery: a card per category screen.
