## 1. Gate

- [x] 1.1 `ExperimentalFeature` (feature, pref key, default) and `ExperimentalFeaturesService` (`switchOn`, `isEnabled`, `setSwitch`, `initialize`, `reload`), with the pure `experimentalFeatureEnabled`.
- [x] 1.2 Register each switch in `kExportedAppPrefs`; initialize at startup beside developer mode; reload after an import.
- [x] 1.3 Tests: truth table, the Tor default, persistence and reload, a wrong-typed pref reading as the default.

## 2. Tor

- [x] 2.1 `TorService.isAvailable` reads `isEnabled(ExperimentalFeature.tor)`.
- [x] 2.2 `TorGate.developerModeOff` becomes `switchedOff`; `torDeveloperGateBody` names both switches.
- [x] 2.3 Tests: the switch off shuts the gate with developer mode on, cannot open it with developer mode off, and releases holders already taken.

## 3. App settings

- [x] 3.1 The Experimental group under Developer, shown while developer mode is on and Tor has a runtime here; the Built-in Tor switch with its hint.
- [x] 3.2 Switching Tor off with sites pinned asks first (TOR-023); developer mode off asks only while the Tor switch is on.
- [x] 3.3 Widget tests in `test/tor_developer_mode_confirm_test.dart`.
- [x] 3.4 Strings: code plus `lib/l10n/app_en.arb` in one commit, the 66 translations (including the changed `torDeveloperGateBody`) in the next.

## 4. Spec

- [x] 4.1 DEVTOOLS-011 here; DEVTOOLS-010, TOR-007, TOR-022 and TOR-023 edited in place in `add-ios-tor-proxy`.
- [x] 4.2 `npx openspec validate --all` passes.
