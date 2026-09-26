# Archive nested container

## Why

An archive-tier site binds an opaque container, `ws-<archiveContainerId>`, so
nothing on disk names it (ARCH-007). Its nested screens did not: the nested
chain never carried `archiveContainerId`. On Android, where an incognito site
still binds a named profile (the SEC-002 fix), a link an archived site opened
ran in a persistent profile named after the site's cleartext id. The page was
signed out of the site, and the profile outlived the archive's close until the
next cold start swept it as an orphan. BUG-019 has the lineage.

## What Changes

- `archiveContainerId` joins the nested chain: `LaunchUrlFunc`, both
  `launchUrlFunc` call sites, `launchUrl`, `_launchNestedForModel`,
  `InAppWebViewScreen` and its `WebViewConfig`. The posture-parity gate moves
  it from `KNOWN_GAP` to `POSTURE`.
- `_closeArchive` also deletes `ws-<siteId>` for the archive's sites that no
  app-tier site shares an id with.

## Capabilities

### Modified Capabilities

- `archive`: ARCH-007 names the nested screen and the close-time sweep.

## Impact

- iOS, macOS and Linux bind no container for an incognito site, so nothing
  changes there; the nested webview keeps its ephemeral store.
- Nothing persisted changes: `archiveContainerId` is runtime state.
