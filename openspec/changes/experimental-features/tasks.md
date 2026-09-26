## 1. Gate

- [x] 1.1 `ExperimentalFeature` (feature, pref key, default) and `ExperimentalFeaturesService` (`switchOn`, `isEnabled`, `setSwitch`, `initialize`, `reload`), with the pure `experimentalFeatureEnabled`.
- [x] 1.2 Register each switch in `kExportedAppPrefs`; initialize at startup beside developer mode; reload after an import.
- [x] 1.3 Tests: truth table, the Tor default, persistence and reload, a wrong-typed pref reading as the default.

## 2. Tor

- [x] 2.1 `TorService.isAvailable` reads `isEnabled(ExperimentalFeature.tor)`.
- [x] 2.2 `TorGate.developerModeOff` becomes `switchedOff`; `torDeveloperGateBody` names both switches.
- [x] 2.3 Tests: the switch off shuts the gate with developer mode on, cannot open it with developer mode off, and releases holders already taken.

## 3. Router mode

- [x] 3.1 `ProxyRouterService.isSupported` reads `isEnabled(ExperimentalFeature.proxyRouter)`; `isSupportedWhen`'s `developerMode` becomes `experimentEnabled`; `canRunHere` answers where the switch is listed.
- [x] 3.2 Tests: the live gate follows the switch with developer mode on and never widens developer mode; the structural gate names the experiment read and confines `canRunHere` to the settings row.

## 4. App settings

- [x] 4.1 The Experimental group under Developer, shown while developer mode is on and some feature can run here; the Built-in Tor switch where Tor has a runtime, the Proxy router switch where the router could run, each with its hint.
- [x] 4.2 Switching Tor off with sites pinned asks first (TOR-023); developer mode off asks only while the Tor switch is on.
- [x] 4.3 Widget tests in `test/tor_developer_mode_confirm_test.dart`.
- [x] 4.4 Strings: code plus `lib/l10n/app_en.arb` in one commit, the 66 translations (including the changed `torDeveloperGateBody`) in the next.

## 5. Spec

- [x] 5.1 DEVTOOLS-011 and the PROXY-013 delta here; DEVTOOLS-010, TOR-007, TOR-022 and TOR-023 edited in place in `add-ios-tor-proxy`.
- [x] 5.2 `npx openspec validate --all` passes.

## 6. Page icons

- [x] 6.1 `ExperimentalFeature.pageIcons`, off by default, registered in `kExportedAppPrefs`; `WebViewFactory.createWebView` builds the ICON-013 fetcher only while it is enabled.
- [x] 6.2 The Page icons switch where `siteIconFetchRunsHere` (iOS, macOS, Linux), with its hint.
- [x] 6.3 Tests: the default and persistence in `test/experimental_features_service_test.dart`, the switch in `test/tor_developer_mode_confirm_test.dart`, the gate read in `test/js/page_bridge_authority.test.js`; `integration_test/site_icon_test.dart` turns it on for the macOS fetch-path run.
- [x] 6.4 Strings: code plus `lib/l10n/app_en.arb` in one commit, the 66 translations in the next.
