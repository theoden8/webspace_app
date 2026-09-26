## 1. Sheet

- [x] 1.1 `containerIdFor` in `webview.dart`, used by `createWebView`.
- [x] 1.2 `SiteInfo`, `SiteContainerKind` and `SiteInfoSheet`.
- [x] 1.3 `UrlBar.onSiteInfo`: trailing (i), hidden while editing.
- [x] 1.4 Main and nested URL bars pass it; the nested menu carries "Site info".

## 2. Routing graduates

- [x] 2.1 Drop `ExperimentalFeature.linkRouting`, its pref and its switch; restore the Experimental group's platform guard.
- [x] 2.2 `routeOutbound` without `experimentEnabled`; the Behaviour screen without `showOutboundRouting`.
- [x] 2.3 DEVTOOLS-011, LIR-014 and BEHAV-003 edited in place.

## 3. Tests

- [x] 3.1 `test/site_info_sheet_test.dart`: container kinds, sheet rows, the URL bar button in both text directions and while editing.
- [x] 3.2 Structural gate: both URL bars pass `onSiteInfo`, `createWebView` binds through `containerIdFor`, and each sheet is built from its webview's own inputs.
- [x] 3.3 Routing tests without the experiment gate.
