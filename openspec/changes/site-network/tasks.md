## 1. Specify

- [x] 1.1 Write `specs/site-network/spec.md` with NET-001 (the screen, its two
  groups, the platform gate, the no-persistent-state contract), NET-002 (the
  row and its summary) and NET-003 (address validated beside the field).
- [x] 1.2 Modify BEHAV-002 where it places the rows: four rows, Network second.
- [x] 1.3 Add the `site-network` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until the change is archived.

## 2. Build the screen

- [x] 2.1 Add `lib/screens/site_network.dart`: `SiteNetworkValues`,
  `validateProxyAddress`, `SiteNetworkScreen` and `SavedSignInsTile`.
- [x] 2.2 Group the rows: "Proxy" (note, type, Tor exit country, address,
  credentials, connection test) and "Connection" (WebRTC policy, saved
  sign-ins).
- [x] 2.3 Take the text controllers and the connection test from the caller:
  the controllers feed the dirty snapshot, and the test runs what a save would
  store.

## 3. Wire it into site settings

- [x] 3.1 Replace the inline Network section in `lib/screens/settings.dart`
  with `_buildNetworkRow` + `_openNetwork`, keeping the fields, the snapshot
  diff and the save path where they are.
- [x] 3.2 Register the Tor exit country in `_currentSnapshot`.

## 4. Strings

- [x] 4.1 Rename `siteSettingsSectionNetwork` to `networkTitle` in all 67
  `lib/l10n/app_*.arb`, keeping every translation.
- [x] 4.2 Add the two group headings and three summary keys in all 67 locales,
  translations in their own commit.

## 5. Gate it

- [x] 5.1 `test/site_network_screen_test.dart`: groups, platform gate, whole-
  value reporting, TOR fields, inline validation, the connection-test slot,
  saved sign-ins.
- [x] 5.2 `test/site_settings_network_row_test.dart`: row order, nothing left
  inline, every summary shape, and an edit on the screen guarding the leave.
- [x] 5.3 Member rule in `test/js/site_settings_dirty_snapshot.test.js`;
  discovery in the TOR-007 gate; classify the new file in the l10n and
  design-token gates.
- [x] 5.4 Replace the `site-settings-signins` gallery card with `site-network`
  (card registry and `tool/design_gallery/shoot.js`).
