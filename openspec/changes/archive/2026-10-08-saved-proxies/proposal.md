# Saved proxies and a connection indicator

## Why

A user with one VPN for several sites had to type the same proxy into each
site's Network screen, and change every copy when the VPN moved. The app-wide
outbound proxy does not cover it: every site on DEFAULT inherits it, so it
cannot route some sites through the VPN and leave the rest direct, and there
is no way to keep two such routes side by side.

Once several sites share one proxy, whether that proxy is up becomes a
question the user asks often, and the only answer so far was a manual test
button inside one site's settings.

## What changes

- **Not experimental.** Everything below shipped first behind developer
  mode and a **Saved proxies** switch (DEVTOOLS-011), off by default. It
  graduated: the switch and its `experimentalProxyLibrary` pref are gone, and
  it is offered with developer mode on or off.

- **A proxy library** (PROXY-030). App Settings gets a "Saved proxies" screen
  with three lists: saved proxies, gateways (type and address) and
  credentials (username, password, and the gateways they work on). A saved
  proxy is a gateway choice plus a credentials choice, each typed or picked
  from the library; with both typed it is simply a proxy, so the one-VPN case
  takes one form. Gateways and credentials are for what is shared: one
  account on several gateways, several accounts on one gateway.
- **Picking from it.** Every proxy picker (a site's Network screen, the
  app-wide proxy) offers saved proxies and gateways by name beside the plain
  types. On a saved gateway, the credentials picker offers only the saved
  credentials that list it, and typed ones. Settings store references
  (`SAVED`/`savedProxyId`, `GATEWAY`/`gatewayId`, `credentialsId`), resolved
  at use by `resolveEffectiveProxy`, so an edit reaches everything that uses
  the entry. An edit or delete disposes every loaded webview, as an app-wide
  proxy change already does.
- **Fail closed.** A reference that does not resolve (a missing entry, or
  credentials paired with a gateway they do not list) carries no address,
  which every seam already treats as unroutable. It never falls through to
  the app-wide proxy or to a direct connection, and every surface names what
  failed.
- **Connection indicator** (PROXY-031). A dot and a line saying whether a
  route answers, checked when shown and on tap: on every saved proxy, under
  the site and app-wide pickers when they use the library, and in a new
  Connection row of the URL-bar site info sheet. It waits a second after the
  route changes, so typing does not probe each keystroke.
- **Storage** (PWD-007). The library rides backups under `proxyLibrary` in
  `kExportedAppPrefs`; passwords live in secure storage under
  `__saved_credentials__:<id>` and `__saved_proxy__:<id>` and never in an
  export.
- **Sharing.** A QR share carries the resolved route (never a password), since
  ids mean nothing on another device; an inbound payload that names the
  library is refused.

## Impact

- `ProxyType` gains `SAVED` (5) and `GATEWAY` (6), appended. A build without
  them reads either index as DEFAULT, the same rollback behaviour TOR has.
- `formal/proxy.tla` is unchanged: its `proxyOf` is the effective proxy, two
  settings that resolve to one route are the aliasing its sites 1 and 3
  already model,
  and an edit disposes every loaded webview before any site reloads, so the
  fixed-assignment abstraction holds between edits.
- ARCH-001 holds: the list is app-tier state, identical whether or not
  archives exist. An archive-tier site may use a library entry; deleting it
  while the archive is closed leaves that site failing closed when opened.
