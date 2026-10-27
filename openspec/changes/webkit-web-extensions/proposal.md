# Proposal

## Why

WebSpace runs no browser extensions, and the ones a user installs in Safari stay
in Safari. WebKit's `WKWebExtension` API (iOS 18.4, macOS 15.4) lets an app load
extensions into its own web views, in the WebExtension format Chrome and Firefox
use, with both the `chrome.*` and `browser.*` namespaces. The app's per-site
model (one container per site) is what makes this safe to offer: each site can
get its own extensions, limited to that site, with nothing shared between sites.

## What Changes

- A new experimental feature, Web extensions, offered only on iOS 18.4+ and
  macOS 15.4+ through the Experimental group (DEVTOOLS-011), default off.
- App Settings > Extensions: a library the user imports into from a file: an
  unpacked folder (macOS), a `.zip`, a Chrome `.crx` or a Firefox `.xpi`. The
  app downloads nothing, checks no store signature and updates nothing on its
  own. Each entry shows what the extension asks for and any errors WebKit
  reported loading it.
- Every extension is off on every site. A site's Settings > Extensions switches
  one on for that site after showing what it asks for.
- An extension on a site sees that site only: host access is granted for the
  site's own domains and denied elsewhere, its storage is per site, its cookie
  access is the site's container, other sites' tabs are invisible to it, and it
  can message no app or native code.
- The site menu shows each enabled extension's action; its popup and options
  page open as sheets within the site.
- Archive-tier and kiosk sites offer no extensions; an incognito site keeps no
  extension data across restarts. Nested screens and popups of a site run the
  site's extensions under the same limits.
- Backups and QR shares carry neither extensions nor which sites enable them.
- The webview fork gains a per-webview extension setting, applied where the
  container is bound. Android and Linux are unchanged.

## Capabilities

### New Capabilities

- `web-extensions`: importing WebExtensions, enabling them per site, the limits
  an extension runs under, and how its own UI shows.

### Modified Capabilities

- `developer-tools`: DEVTOOLS-011's table of experimental features gains Web
  extensions, offered only where WebKit runs them.

## Impact

- `flutter_inappwebview` fork (iOS and macOS): a `webExtensions` setting on
  `InAppWebViewSettings`, a controller per container, the grants applied to each
  context, and a `WKWebExtensionControllerDelegate` that answers tabs, windows,
  popups and refusals. XCTests in the fork; a new fork tag and pin.
- New pure Dart engines in `lib/services/`: the package import (CRX header,
  ZIP validation, manifest summary), the grants plan and the attach plan.
- New per-site field (`SiteField`, a `SitePosture` group), a library store, an
  `OrphanStore` entry for per-site extension data, an `AppPref` for the switch.
- New screens: App Settings > Extensions, a site's Extensions screen; site menu
  entries; strings in `lib/l10n/app_en.arb` plus translations in their own
  commit.
- Tests: engine tables with planted mutants, posture and backup tests, Swift
  XCTests, and a macOS integration test on CI with an extension built at test
  time.
- App Store: guideline 2.5.2 and 4.7 apply to code the user loads; the feature
  stays behind developer mode until App Review has been asked.
