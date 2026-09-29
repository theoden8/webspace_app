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

- **Saved proxies** (PROXY-029). App Settings gets a "Saved proxies" screen: a
  list of named HTTP, HTTPS or SOCKS5 proxies, each defined once. Every proxy
  picker (a site's Network screen, the app-wide proxy) offers them by name
  beside the plain types. A site stores a reference (`ProxyType.SAVED` plus
  `savedProxyId`), resolved at use by `resolveEffectiveProxy`, so editing a
  saved proxy moves every site that names it. An edit or delete disposes every
  loaded webview, as an app-wide proxy change already does.
- **Fail closed on a missing saved proxy.** A reference that resolves to
  nothing (deleted, or carried in from elsewhere) is SAVED with no address,
  which every seam already treats as unroutable. It never falls through to
  the app-wide proxy or to a direct connection.
- **Connection indicator** (PROXY-030). A dot and a line saying whether a
  proxy answers, checked when shown and on tap: on every row of the saved
  proxies list, under a site's picker when it names a saved proxy, under the
  app-wide picker when it names one, and in a new Connection row of the
  URL-bar site info sheet, which names the route the site takes.
- **Storage** (PWD-007). The list rides backups under `savedProxies` in
  `kExportedAppPrefs`; each password lives in secure storage under
  `__saved_proxy__:<id>` and never in an export.
- **Sharing.** A QR share inlines the saved proxy's own fields (never its
  password), since an id means nothing on another device; an inbound payload
  naming a saved proxy is refused.

## Impact

- `ProxyType` gains `SAVED` (index 5, appended). A build without it reads the
  index as DEFAULT, the same rollback behaviour TOR has.
- `formal/proxy.tla` is unchanged: its `proxyOf` is the effective proxy, two
  sites on one saved proxy are the aliasing its sites 1 and 3 already model,
  and an edit disposes every loaded webview before any site reloads, so the
  fixed-assignment abstraction holds between edits.
- ARCH-001 holds: the list is app-tier state, identical whether or not
  archives exist. An archive-tier site may name a saved proxy; deleting it
  while the archive is closed leaves that site failing closed when opened.
