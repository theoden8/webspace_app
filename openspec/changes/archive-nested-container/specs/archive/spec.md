## MODIFIED Requirements

### Requirement: ARCH-007 — Container lifecycle for archive-tier sites

For archive-tier sites on container-capable platforms, per-site containers SHALL use opaque, key-derived identifiers and SHALL be torn down on archive close. The archive feature is unavailable on platforms without container support.

Every webview that runs as an archive-tier site SHALL bind by that opaque identifier: the site's own webview, and a nested `InAppWebViewScreen` opened from its links, from its URL bar, or routed to it (link-intent-routing LIR-015). `archiveContainerId` is therefore part of the nested chain (`LaunchUrlFunc`, `launchUrl`, `InAppWebViewScreen`), like any posture field (NESTED-010). A nested screen that bound `ws-<siteId>` instead would, on Android, where incognito sites still bind a named profile, run in a persistent profile named after the archived site's cleartext id, signed out of the site, and left on disk by the close.

On close, after deleting the archive's opaque containers, `_closeArchive` SHALL also delete `ws-<siteId>` for each of the archive's sites whose id no app-tier site holds, so a path that ever binds one without the opaque id leaves nothing behind. An id an app-tier site also holds (a backup can bring one back) is skipped: that container is the app-tier site's own.

#### Scenario: Opaque container id for archive sites

**Given** an archive site with stored `siteId = S`
**And** the archive is open with key `MK_arch`
**When** the container is created for that site
**Then** the container name is `ws-<X>` where `X = HMAC-SHA256(MK_arch, "container:" + S)` truncated and re-encoded to match the radix-36 / dash / radix-36 shape of an app-tier `siteId`
**And** the radix-36 string lengths fall within the same range as the app-tier siteId distribution

#### Scenario: Container torn down on archive close

**Given** archive A is open and has containers `C_1, C_2, ... C_n`
**When** the archive is closed
**Then** for each `C_i`, `ContainerNative.deleteContainer(C_i)` is called
**And** no on-disk container directory survives the close (best-effort — see Limitations)

#### Scenario: A nested screen of an archive site binds its opaque container

**Given** an open archive holding site S, whose container is `ws-<X>`
**When** the user taps a cross-domain link in S and it opens in a nested screen, on Android
**Then** the nested webview binds `ws-<X>`
**And** no container named `ws-<S>` is created

#### Scenario: Close sweeps a cleartext-named container

**Given** a container `ws-<S>` exists for archive site S (left by a build before this rule)
**And** no app-tier site has id S
**When** the archive is closed
**Then** `ws-<S>` is deleted with the archive's opaque containers

#### Scenario: Close leaves an app-tier site's container alone

**Given** archive A holds site S and an app-tier site also has id S (restored from an old backup)
**When** A is closed
**Then** the app-tier site's container `ws-<S>` is not deleted

#### Scenario: Cookies survive across archive sessions

**Given** the user logs in to site S in archive A and closes the archive
**When** the user reopens archive A in a later session
**Then** the cookies the user obtained during the previous session are present in S's freshly-recreated container
**Because** cookies were flushed to the archive's ciphertext slot on close and rehydrated into the container on open via the existing `cookie_secure_storage` capture-restore API

#### Scenario: Feature unavailable when containers are not supported

**Given** the runtime check `ContainerNative.isSupported() == false`
**When** the user opens the settings screen
**Then** the archive entry point is disabled with a subtitle explaining the platform requirement
