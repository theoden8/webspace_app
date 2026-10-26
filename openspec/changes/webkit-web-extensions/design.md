# Design

## Context

- Every webview that runs as a site is built from one `SitePosture`
  (NESTED-010); `SitePage` already carries the site's user scripts.
- On iOS and macOS each site's webview is bound to its container in the fork's
  `preWKWebViewConfiguration`, through `InAppWebViewSettings.containerId` and
  `ContainerManager` (`containerIdToUUID`, a SHA-256 derived UUID). Containers
  exist on iOS 17+ and macOS 14+, so every system that has `WKWebExtension`
  (iOS 18.4, macOS 15.4) has them.
- `WKWebViewConfiguration` takes one `webExtensionController`; a controller is
  created from a `Configuration` that is `default()`, `nonPersistent()` or
  `init(identifier: UUID)`, and has a `defaultWebsiteDataStore`. A context per
  extension is loaded into a controller, and its permissions and host match
  patterns are granted or denied on the context.
- A site has one live webview at a time; its inactive tabs are saved history
  (`WebViewTabBinding`), not webviews. Its nested screens and popups are
  webviews of their own.
- The Runner and the fork are both sandboxed on macOS; files reach the app
  through `FileDialog`.

## Goals / Non-Goals

**Goals:**

- WebKit's own extension runtime, with the app deciding only what each context
  may reach.
- Every decision that is not a WebKit call in a pure Dart engine with a table
  test, so the fork's native code applies a plan it is handed and decides
  nothing about sites.
- Per-site isolation held by a test that fails if two sites share an
  extension's storage or host access.

**Non-Goals:**

- A store, an update check, signature verification or downloading packages.
- Android and Linux (no extension runtime in Android System WebView; WPE's is
  unfinished upstream).
- Extension keyboard commands, context menus, `devtools_page`, side panels.
- Exposing a site's inactive tabs (no webview holds them) or other sites.

## Decisions

### D1. WebKit's runtime, not a translation into user scripts

The alternative was reading a manifest's `content_scripts` and
`declarative_net_request` rules into the user script and content blocker
engines, which would run on all four platforms. It was rejected: almost every
extension calls `chrome.storage`, `runtime.sendMessage` or a background page,
none of which a user script has, so few extensions would work, and the app would
own a second WebExtension runtime.

### D2. One controller per site, named by its container

The fork keeps one `WKWebExtensionController` per container id, created with
`Configuration(identifier: containerIdToUUID(containerId))` and
`defaultWebsiteDataStore` set to the container's data store, or
`nonPersistent()` for an incognito site. Extension storage and cookie access
then follow the site's container with no app code in between (WEBEXT-006).

The alternative, one app-wide controller with every site's tabs in it, shares
`storage.local` and background pages across sites: an extension enabled on two
sites becomes a channel between their containers, which defeats
`per-site-containers`.

### D3. Grants are a plan the Dart side computes

`planExtensionGrants(entry, claims:)` (`lib/services/web_extension_grants_engine.dart`,
WEBEXT-014, WEBEXT-015) is a pure function from what an extension asked for
(its library entry keeps the manifest's permissions and host patterns) and the
site's domain claims (`effectiveDomainClaims`) to an `ExtensionGrants` record:

- host patterns: for each pattern asked for and each pattern the claims cover
  (`siteMatchPatterns`), the pages both name: the narrower host, the narrower
  scheme, the path asked for. `<all_urls>` on a site claiming `example.com`
  becomes `*://*.example.com/*`; a request for `https://mail.example.com/*`
  stays that. Hosts are compared on a dot boundary. A wildcard claim's pattern
  takes the bare host too, which a match pattern cannot leave out; a claim with
  a port grants nothing, since match patterns do not name ports.
- permissions: what it asked for that is on `grantablePermissions`;
  `nativeMessaging` never is.

The fork applies the grants with `setPermissionStatus(.grantedExplicitly, for:)`
before it loads the context, and its delegate answers `promptForPermissions`,
`promptForPermissionMatchPatterns` and `promptForPermissionToAccess` from the
same grants without showing anything (WEBEXT-005). The user consents once,
per site, when switching the extension on (WEBEXT-004), which is also what App
Store guideline 4.7.3 asks.

### D4. What a webview gets is a sealed plan

`planExtensionAttach(ExtensionAttachInputs)` (`lib/services/web_extension_attach_engine.dart`,
WEBEXT-016) returns a sealed `ExtensionAttach`, the reasons checked in this order:

- `NoExtensions(reason)`, with `reason` an enum: `unsupported`,
  `experimentOff`, `archive`, `kiosk`, `noneEnabled`;
- `AttachExtensions(controller: persistent(uuid) | nonPersistent, contexts: [(id, path, grants)])`.

It is resolved once in `WebViewModel.sitePosture` into `SitePage.extensions`,
so the site's webview, its nested screens and popups and a background wake's
headless check get the same plan (WEBEXT-010). `forNested()` keeps it. The
factory hands `AttachExtensions` to the fork as the `webExtensions` setting.

### D5. Import is a pure reader of the package's bytes

`readExtensionPackage(bytes)` (`lib/services/web_extension_package_engine.dart`)
returns a sealed `PackageRead`: an `ExtensionPackage` (format, files by path,
manifest summary) or a `PackageRefused` whose sealed `PackageRefusal` names
the reason the import screen shows (WEBEXT-013).

- The format is told from the bytes (`envelopeOf`): `Cr24` version 2 (key
  length, signature length, key, signature) and version 3 (header length,
  header) are cut to the archive after the header; a ZIP is read as it is.
  No signature is read; the package says whether it carried one.
- The ZIP is read by the engine itself, not by `package:archive`'s decoder,
  which merges duplicate names, skips the CRC check, ignores the encryption
  flag and raises `RangeError` on a malformed directory. Every offset is
  checked before use, and every entry before any is inflated: UTF-8 name,
  no absolute path, `..`, `.`, empty segment, backslash or control
  character, no symlink, no path equal to another ignoring case (a
  case-insensitive file system) or running through another file; stored or
  deflate only; no encryption, ZIP64 or split archive; caps on entries and
  on declared total size (`PackageLimits`).
- Deflate goes through the platform's zlib (`hostDeflateDecoder`, raw) via
  `inflateBounded` (`lib/services/bounded_inflate.dart`), the one bounded
  inflation the download engine and the QR codec now share: output stops
  where it passes the entry's declared size, then the size and CRC must
  match. `package:archive`'s pure Dart `Inflate` was rejected: 4.0.9 loops
  forever on some 50-byte streams and raises `RangeError` on others.
- `manifest.json` at the root must parse (a byte order mark allowed) with
  `manifest_version` 2 or 3, a name and a version; `__MSG_` names resolve
  from `default_locale`'s messages, case-insensitively as Chrome does. The
  summary splits API permissions from hosts (Manifest V2's patterns among
  permissions, `host_permissions`, content script matches), and reads the
  optional ones, the background kind, an action and an options page.

The engine does no I/O; writing the files under
`<app support>/web_extensions/<WebExtensionId>/` is the store's (task 2.3).
`WebExtensionId` is an extension type minted on import (CLAUDE.md rule 5);
the manifest's own `key` or Gecko id is not trusted as identity.

### D6. Storage and lifecycle

- The library is a list of `{id, name, version, path}` in a store beside the
  user scripts' (`ShellStore`), not in backups (WEBEXT-011).
- A site's choice is a `SiteField` (`enabledWebExtensions`, a set of ids), QR
  `false`; `planSettingsImport` drops it as it drops user script opt-ins
  (BACKUP-011).
- The switch is an `AppPref` in the Experimental group, read through
  `ExperimentalFeaturesService` and offered when `WebExtensionSupport.probe`
  says the system has the API.
- Deleting a site asks the fork to remove the controller's data records; the
  store is an `OrphanStore` value (`webExtensionData`, scope session), so the
  orphan sweep covers sites deleted while the app was not running.
- Removing a library entry deletes its folder and its data records on every
  controller, and drops its id from every site.

### D7. The delegate in the fork

The fork's delegate answers each call from the controller's site only:

| Delegate call | Answer |
|---|---|
| `openWindowsFor`, `focusedWindowFor` | the site's one window, whose tabs are the site's live webviews (its own, its nested screens, its popups) |
| `openNewTabUsing` | an extension page: a sheet over the site; a URL the grants cover: a nested screen through the app (`launchUrl`); otherwise an error |
| `openNewWindowUsing` | an error |
| `presentActionPopup` | the action's popup, natively (a popover on macOS, a sheet on iOS) |
| `openOptionsPageFor` | a sheet with the options page |
| `sendMessage(toApplicationWithIdentifier:)`, `connectUsing` | an error |
| the three `promptFor...` calls | the D3 grants, no UI |

The site menu reads each attached context's action (title, icon, badge) through
a method channel and calls `performAction` when picked.

### D8. Activation model

Attaching happens in `preWKWebViewConfiguration`, inside the webview build, and
detaching when the webview goes: neither adds an await to a step table. If
removing data on delete needs one, it becomes a `Step` of
`SiteDeletion.deleteTable`, and `./formal/verify.sh` must pass before that push.

### D9. How it is tested

| Layer | Test | Planted mistake it must catch |
|---|---|---|
| Package | `test/web_extension_package_test.dart`: CRX2, CRX3, ZIP and signed XPI built byte by byte in the test (`test/helpers/extension_packages.dart`); envelope and entry-name tables; every unsafe entry kind; encryption, ZIP64, split archives and other methods; lying sizes and CRCs; a deflate bomb; the stream that loops a pure Dart inflater; manifest problems, locales, permissions and background kinds; 3000 seeded damaged packages read or refused the same way twice | CRX3 header length read as CRX2's; a `..` segment let through; inflating through `package:archive`'s `Inflate` (the looping stream times out) |
| Grants | `test/web_extension_grants_test.dart`: manifests by claims, including `<all_urls>`, `*://*/*`, wildcard claims, IP hosts, `file:` | `<all_urls>` passed through; a wildcard claim granting the bare suffix's siblings; `nativeMessaging` allowed |
| Attach plan | `test/web_extension_attach_test.dart`: the matrix of support, experiment, archive, kiosk, incognito and enabled sets, each cell's `ExtensionAttach` | archive tier ignored; incognito given a persistent controller |
| Posture | NESTED-010's posture test gains the field; `forNested()` keeps it | `forNested()` dropping it |
| Backup and QR | `test/settings_backup_test.dart`, the QR codec test: no extension key exported, import enables none | import keeping `enabledWebExtensions` |
| Screens | widget tests of App Settings > Extensions (import summary, errors, removal) and a site's Extensions (consent sheet, archive lock) | switching on without the consent sheet |
| Fork | XCTests in the fork's `RunnerTests`: one controller per container id, reused; grants applied to a loaded context; delegate refuses native messaging and windows | a controller shared across container ids |
| End to end | `integration_test/web_extensions_test.dart` on the macOS CI job (macOS 15.4+), with an extension written at test time (a content script setting `data-ws-ext` and storing a value): runs on site A, not on site B; A's stored value unreadable from B; no injection into A's nested screen on another host | D2 replaced by one shared controller |

Swift sources are type-checked by `tool/swift_typecheck/check.sh`. Test names
cite WEBEXT-001 to WEBEXT-012.

## Risks / Trade-offs

- [App Review treats user-loaded extensions as code under 2.5.2] → behind
  developer mode and an experiment switch; ask App Review (4.7) before it
  graduates.
- [Extension compatibility varies; WebKit's API is young] → errors shown per
  extension (WEBEXT-003); an extension that fails to load is offered to no site.
- [A background page per extension per loaded site costs memory] → contexts
  load with the site's webview and unload with it, so lazy loading and memory
  pressure eviction cover them; the import summary warns about persistent
  background pages.
- [Narrowed host access breaks an extension that expects every site] → by
  design; the consent sheet says access is limited to the site.
- [The fork grows a second iOS/macOS-only surface] → one setting, one
  controller cache and one delegate; the plan arrives as data, so the native
  side holds no per-site rule.

## Migration Plan

New feature behind a switch that defaults off. Rollback is turning the switch
off (WEBEXT-012); removing the feature deletes the library folder and the
`webExtensionData` records through the orphan sweep.

## Open Questions

- Whether the iOS simulator job can run the integration test as well as the
  macOS job; the test is written for both, and the CI wiring is decided when
  it lands.
