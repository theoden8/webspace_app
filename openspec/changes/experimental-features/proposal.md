## Why

Developer mode opens two unrelated things at once: diagnostic tools, and every
feature that ships before it is finished. Today that is only Tor; outbound link
routing (#345) and router mode are next. A developer who wants the Repaint
action, or wants to try one experimental feature, gets all of them, and has no
way to turn one off without losing the rest.

## What Changes

- An **Experimental** group in App settings > Developer, shown only while
  developer mode is on. It holds one switch per experimental feature, each with
  its explanation behind a hint.
- A feature is reachable when developer mode **and** its own switch are on
  (DEVTOOLS-011). The switch only narrows developer mode, so "is this feature
  reachable" still has one answer, which is what DEVTOOLS-010 required.
- `ExperimentalFeaturesService` is the single reader, like
  `DeveloperModeService`: `isEnabled(feature)`, per-feature prefs registered in
  `kExportedAppPrefs`, re-read after an import.
- **Tor** is the first feature. `TorService.isAvailable` reads the service
  instead of developer mode. The switch defaults on, so a user who had developer
  mode on keeps Tor. Switching it off asks first when sites are pinned to Tor
  (TOR-023), exactly as turning developer mode off does, and releases the
  runtime's holders. The interstitial's `TorGate.developerModeOff` becomes
  `switchedOff`, and its text names both switches.
- **Router mode** (PROXY-013) is the second. `ProxyRouterService.isSupported`
  reads the service instead of developer mode, still once at launch, so the
  switch applies at next start. It defaults on for the same reason as Tor.
  App settings lists it only where the router could run (Android with
  `MULTI_PROFILE`), which `ProxyRouterService.canRunHere` answers.
- Outbound link routing joins the group in #345, which is stacked on this
  change.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `developer-tools`: adds DEVTOOLS-011 (the Experimental group). DEVTOOLS-010's
  text in `add-ios-tor-proxy` now points at it.
- `proxy`: PROXY-013's developer-mode gate becomes the Proxy router switch.
- `tor-proxy` (in `add-ios-tor-proxy`, not archived): TOR-007, TOR-022 and
  TOR-023 read the Built-in Tor switch alongside developer mode. Edited in place,
  since that change is where those requirements live today.

## Impact

- `lib/services/experimental_features_service.dart` (new),
  `lib/settings/app_prefs.dart`, `lib/main.dart` (initialize, reload after
  import), `lib/services/tor_service.dart`, `lib/services/tor_engine.dart`,
  `lib/widgets/tor_bootstrap.dart`, `lib/screens/app_settings.dart`,
  `lib/services/proxy_router_service.dart`.
- Strings: the group heading, its hint, the Tor switch and hint, the Tor switch's
  confirmation, and the Proxy router switch and hint. `torDeveloperGateBody` changes to name both switches.
- Tests: the gate's truth table, persistence and defaults
  (`test/experimental_features_service_test.dart`); the Tor gate
  (`test/tor_developer_mode_gate_test.dart`); the App settings group and its
  confirmation (`test/tor_developer_mode_confirm_test.dart`); the router gate
  (`test/proxy_router_service_test.dart`,
  `test/js/proxy_router_developer_gate.test.js`).
