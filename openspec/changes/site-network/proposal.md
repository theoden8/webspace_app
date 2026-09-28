## Why

Site settings sends three of its groups to screens of their own: Behaviour,
Privacy and Permissions each became one row with a summary, because a reader
opens them deliberately and wants the whole topic in one place. Network did
not. Its controls stayed inline between the content controls and the "Site"
rows: a shared-proxy note, the proxy type with its coverage caption, a Tor exit
country, an address field, a credentials fold, a connection test, the WebRTC
policy and the saved sign-ins row. That is up to eight rows with three text
fields among them, and it is the longest stretch left on the screen.

It is the same kind of group as the other three: one topic (how the site's
traffic reaches the internet), edited deliberately, and never on the way to
something else. The proxy rows also need room the inline layout could not give
them: the address is validated only by the save button at the bottom of the
screen, so a malformed one surfaced as a snackbar far from the field.

Moving the fields also exposed a gap. The Tor exit country is written into the
form's proxy object in place, and the dirty snapshot recorded that object's
type but not its exit country, so pinning a country and backing out dropped it
without the unsaved-changes prompt (BUG-006). The snapshot gate checked only
that the object was registered, not each member written into it.

## What Changes

- **A Network screen.** New `SiteNetworkScreen`
  ([lib/screens/site_network.dart](../../../lib/screens/site_network.dart)),
  built like its three siblings: a value object in (`SiteNetworkValues`: proxy
  type, Tor exit country, WebRTC policy), whole values out through
  `onChanged`, no persistent state of its own. The proxy address and
  credentials are text, so they stay in the settings screen's controllers,
  which the dirty snapshot already reads. Two groups: "Proxy" (hidden where the
  platform cannot bind one, PROXY-006) and "Connection" (WebRTC policy, saved
  sign-ins).
- **A fourth row under "Site".** Behaviour, Network, Privacy, Permissions, in
  that order. Network follows Behaviour because both are how the app carries
  the site; the two after them are what the site may learn and reach. The row
  names the route the traffic takes: the site's own proxy (type and address,
  or TOR and its pinned exit), "App-wide proxy" for a site that has none of
  its own while App Settings sets one, and a non-default WebRTC policy; or
  "Default connection".
- **The address is checked where it is typed.** The field validates on edit
  with the same rule the save path runs (`validateProxyAddress`, beside the
  field).
- **The exit country is dirty-tracked.** It joins the snapshot, and the gate
  now also requires every member written into a form object in place to be
  registered (BUG-006, attempt 4).
- **The TOR-007 gate finds dropdowns itself.** It listed the two screens that
  render a `ProxyType` dropdown; the per-site one moving file would have left
  it checking nothing. It now scans `lib/screens` and `lib/widgets`.
- Nothing else moves. No setting is added, removed, defaulted differently or
  re-scoped; the save path is the one that was already there.

## Impact

- New: `lib/screens/site_network.dart`, `test/site_network_screen_test.dart`,
  `test/site_settings_network_row_test.dart`.
- `lib/screens/settings.dart`: the Network section becomes `_buildNetworkRow`
  + `_openNetwork`; the saved sign-ins row moves to the new screen as
  `SavedSignInsTile`.
- `lib/l10n/app_*.arb` (67 files): `siteSettingsSectionNetwork` renamed to
  `networkTitle` keeping every translation (it is now a screen title, not a
  section heading); five keys added: `networkGroupProxy`,
  `networkGroupConnection`, `networkSummaryDefault`, `networkSummaryAppProxy`,
  `networkSummaryWebRtc`.
- Design gallery: the `site-settings-signins` card becomes `site-network`,
  since the saved sign-ins row no longer renders on the settings screen.
- Gates: `test/js/site_settings_dirty_snapshot.test.js` (member rule),
  `test/js/ios_compliance_declarations.test.js` (TOR-007 discovery), and the
  new file classified in the l10n and design-token gates.
- Spec: new capability `site-network`; `site-behaviour`'s BEHAV-002 modified
  where it places the rows. That requirement is also modified by the
  unarchived `external-link-mode` change; the delta here carries that change's
  summary text, so whichever of the two archives second keeps both.
