## 1. Specify

- [x] 1.1 PROXY-030 (saved proxies) and PROXY-031 (connection indicator) in
  the proxy delta.
- [x] 1.2 LEAK-001: the precedence ladder resolves a saved proxy on both the
  site rung and the app-wide rung, and a missing one fails closed.
- [x] 1.3 PWD-007: where a saved proxy's password lives.

## 2. Model and resolution

- [x] 2.1 `ProxyType.SAVED` and `ProxyType.GATEWAY`; `savedProxyId`,
  `gatewayId`, `credentialsId` on `UserProxySettings`.
- [x] 2.2 `lib/settings/proxy_library.dart`: `SavedGateway`,
  `SavedCredentials`, `SavedProxy`, `ProxyLibraryData`, `ProxyLibrary`
  (prefs + secure storage), `resolveLibrary` with the reason a route fails,
  `usesLibraryEntry`.
- [x] 2.3 `resolveEffectiveProxy` resolves the library on the site and the
  global.
- [x] 2.4 Every exhaustive switch and address parser fails closed on an
  unresolved route: Dart HTTP, the loopback relay, the router encoder, the
  auth relay, `userProxyToInappProxy`.
- [x] 2.5 `kExportedAppPrefs` registers `proxyLibrary`; startup initializes
  it, import reloads it without passwords, the import hint counts its
  usernames, the import review resolves an app-wide proxy against it.
- [x] 2.6 QR: resolve on share, refuse on receive.

## 3. UI

- [x] 3.1 `ProxyLibraryScreen` with saved proxies, gateways and credentials;
  `SavedProxyEditScreen`, `SavedGatewayEditScreen`,
  `SavedCredentialsEditScreen`.
- [x] 3.2 `ProxyChoiceDropdown` (saved proxies and gateways under headings),
  `ProxyCredentialsDropdown` (only credentials that fit), `ProxyRouteFields`;
  shared by the site, app-wide and saved proxy forms.
- [x] 3.3 `ProxyHealthService` + `ProxyStatusIndicator`, debounced on change.
- [x] 3.4 Network row summary and site info sheet name the entry or what
  failed.
- [x] 3.5 Gallery cards `saved-proxies`, `saved-proxy-edit`,
  `saved-credentials-edit`, `site-network-saved`; `site-info` shows the
  Connection row.

## 4. Tests

- [x] 4.1 `test/proxy_library_test.dart`: resolution for each shape, every
  failure reason, fail-closed seams, PROXY-008, serialisation, storage, form,
  QR, import planning, usage.
- [x] 4.2 `test/proxy_health_service_test.dart`.
- [x] 4.3 `test/proxy_library_screen_test.dart`: library screen and editors,
  pickers, Network screen, indicator debounce, site info sheet.
- [x] 4.4 TOR-007 gate follows the shared picker.

## 5. Graduate

- [x] 5.1 Take the library out of developer mode and the Experimental group:
  `ExperimentalFeature.proxyLibrary`, its `experimentalProxyLibrary` pref
  (retired in the compat and prefs-history tests) and the pickers'
  `offerLibrary` are gone; the site info sheet's Connection row follows
  PROXY-006 alone. Tests: `test/proxy_library_screen_test.dart`,
  `test/app_settings_experimental_test.dart`,
  `test/experimental_features_service_test.dart`.
