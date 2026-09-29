## 1. Specify

- [x] 1.1 PROXY-029 (saved proxies) and PROXY-030 (connection indicator) in
  the proxy delta.
- [x] 1.2 LEAK-001: the precedence ladder resolves a saved proxy on both the
  site rung and the app-wide rung, and a missing one fails closed.
- [x] 1.3 PWD-007: where a saved proxy's password lives.

## 2. Model and resolution

- [x] 2.1 `ProxyType.SAVED`, `UserProxySettings.savedProxyId`.
- [x] 2.2 `lib/settings/saved_proxies.dart`: `SavedProxy`, `SavedProxies`
  (prefs + secure storage), `resolveSavedProxy`.
- [x] 2.3 `resolveEffectiveProxy` resolves SAVED on the site and the global.
- [x] 2.4 Every exhaustive switch and address parser fails closed on an
  unresolved SAVED: Dart HTTP, the loopback relay, the router encoder, the
  auth relay, `userProxyToInappProxy`.
- [x] 2.5 `kExportedAppPrefs` registers `savedProxies`; startup initializes it,
  import reloads it without passwords, the import hint counts its usernames.
- [x] 2.6 QR: inline on share, refuse on receive.

## 3. UI

- [x] 3.1 `SavedProxiesScreen` / `SavedProxyEditScreen`.
- [x] 3.2 `ProxyChoiceDropdown`, shared by the site and app-wide forms.
- [x] 3.3 `ProxyHealthService` + `ProxyStatusIndicator`.
- [x] 3.4 Network row summary names the saved proxy; site info sheet gains a
  Connection row.
- [x] 3.5 Gallery cards `saved-proxies`, `saved-proxy-edit`,
  `site-network-saved`; `site-info` shows the Connection row.

## 3b. Parting from a saved proxy

- [x] 3b.1 `ownAddress` / `ownCredentials` on `UserProxySettings`, applied by
  `SavedProxy.resolveFor`; `applyProxyForm` treats each field as visible only
  while its switch is on.
- [x] 3b.2 `SavedProxyOverrides`, shared by the site Network screen and the
  app-wide form; the status row follows the overrides as they are typed, and
  the indicator waits a second after a change before probing.

## 4. Tests

- [x] 4.1 `test/saved_proxies_test.dart`: resolution, fail-closed seams,
  PROXY-008 co-loading, serialisation, storage, form, QR, import planning.
- [x] 4.2 `test/proxy_health_service_test.dart`.
- [x] 4.3 `test/saved_proxies_screen_test.dart`: list, add, validate, delete,
  picker, Network screen, site info sheet.
- [x] 4.4 TOR-007 gate follows the shared picker.
