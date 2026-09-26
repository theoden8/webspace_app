## 1. Model

- [x] 1.1 `ExternalLinkMode` and `externalLinkModeFromJson` in `lib/settings/external_links.dart`, reading the legacy bool.
- [x] 1.2 `WebViewModel.externalLinkMode`, `effectiveExternalLinkMode` (ARCH-006), `effectiveRouteOutboundLinks`; JSON omitted at the default.
- [x] 1.3 `externalLinksInBrowser` -> `externalLinkMode` in `_renamedKeys`, `superset.json`, the effective-getter gate and the QR exclusion list.

## 2. Navigation

- [x] 2.1 `NavigationDecision.blockOutbound`; the engine takes the mode.
- [x] 2.2 Both `getWebView` branches cancel and hand the link to the hook; the host shows "Link to {host} blocked" for a tapped link.
- [x] 2.3 The nested screen applies the mode against the page it shows.
- [x] 2.4 The nested chain carries `externalLinkMode`.

## 3. Routing

- [x] 3.1 `routeOutbound` routes `blockOpenNested` only; the host passes `effectiveRouteOutboundLinks`.
- [x] 3.2 Drop `OutboundFallback`, `DispatchOpenExternal` and `unroutedOutbound`; "Open without routing" nests with the source posture.

## 4. UI

- [x] 4.1 Behaviour screen: the External links radio choice with its hint; routing rows under "Open in the app".
- [x] 4.2 Behaviour row summary names the browser and block modes; routing only in the in-app mode.
- [x] 4.3 Strings in `app_en.arb`, translations in their own commit.

## 5. Tests

- [x] 5.1 Engine: block mode for taps, script navigations, claims, same domain, `onUrlChanged`.
- [x] 5.2 Model: default omitted, round-trip, legacy bool, odd values, archive override, routing gate.
- [x] 5.3 Behaviour screen: the choice, its hint, selection, routing rows by mode.
- [x] 5.4 Routing engine: only nested decisions route; funnel gate covers the blocked branches.
