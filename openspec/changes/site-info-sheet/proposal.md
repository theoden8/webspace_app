# Site info sheet

## Why

A nested screen runs as some site: the one whose link opened it, or, with
outbound routing (LIR-015), the one that claims the link. Its app bar shows the
page title and nothing else, so a user cannot tell whose login, cookies and
container a page is using. That is the question routing makes matter: the same
GitHub page is signed in or not depending on which site it runs as.

Routing has been behind developer mode and an experimental switch
(DEVTOOLS-011) since it landed, partly because nothing on screen said where a
routed link went. With the sheet in place it ships: the per-site "Route links
to my sites" switch, off by default, is the only gate.

## What Changes

- **`UrlBar.onSiteInfo`**: an (i) button at the trailing end of the URL bar,
  which the row's text direction puts on the left in a right-to-left locale.
  Hidden while the URL is being edited, where the Go button takes the slot.
- **`SiteInfoSheet`** (`lib/widgets/site_info_sheet.dart`): the site the page
  runs as, the page URL, and the container: the site's own (with its
  `ws-<id>` name), a private store thrown away on close, or the shared store of
  the legacy engine.
- **`containerIdFor`** in `lib/services/webview.dart`: the rule
  `WebViewFactory.createWebView` binds a container by, extracted so the sheet
  reports exactly what was bound. The main screen passes the site's
  `archiveContainerId` and `effectiveIncognito`, the nested screen its
  `siteId` and `incognito`, the same inputs their `WebViewConfig`s carry.
- **Main and nested URL bars** pass the handler; the nested screen's overflow
  menu also carries "Site info", since the URL bar is optional there.
- **Link routing graduates**: `ExperimentalFeature.linkRouting`, its pref
  (`experimentalLinkRouting`, never in a release) and its App settings switch
  are removed; `routeOutbound` loses its `experimentEnabled` gate; the
  Behaviour screen always shows the routing rows. The Experimental group again
  appears only where Tor or the proxy router runs.

## Capabilities

### Modified Capabilities

- `navigation`: NAV-011 (the site info sheet).
- `developer-tools` (in-flight change `experimental-features`): DEVTOOLS-011
  loses its link-routing row, edited in place.
- `link-intent-routing` and `site-behaviour` (in-flight change
  `route-outbound-via-lir`): LIR-014 loses the experiment gate and BEHAV-003
  its visibility rule, edited in place.

## Impact

- New UI file `lib/widgets/site_info_sheet.dart`, classified as migrated in
  the no-hardcoded-text gate; eight new strings.
- The sheet reads state only: nothing persisted, nothing exported.
- A stored `experimentalLinkRouting` pref on a device that had the experiment
  is left in place and no longer read.
