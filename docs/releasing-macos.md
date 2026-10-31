# Releasing macOS

macOS is a shipping target: a notarized Developer ID build on GitHub
releases, and a sandboxed Mac App Store build under the same bundle
identifier as the iOS app. Spec: PLATFORM-006 in
[openspec/specs/platform-support/spec.md](../openspec/specs/platform-support/spec.md).

Each channel is its own build from the same commit, the two differing in
one define (the extension search, below). `flutter build macos --release`
produces an unsigned universal bundle (arm64 + x86_64; `ONLY_ACTIVE_ARCH` is
Debug-only, and the adblock static lib is already fat), and
[scripts/sign_macos.sh](../scripts/sign_macos.sh) signs it for the channel
you want. Nothing about the release identity lives in the Xcode project.

## What the CI artifact is

`build-and-test.yml` uploads `webspace-macos.zip` on every push. It is a
developer build and nothing more:

- No team, so `$(AppIdentifierPrefix)` in the entitlements expands to
  nothing. The build step re-signs it ad-hoc with the app-group and
  keychain-access-group keys removed, because taskgated SIGKILLs an ad-hoc
  bundle that names either one ("Code Signature Invalid", no dialog).
- With no keychain access group, `flutter_secure_storage` fails every read
  and write with `errSecMissingEntitlement` (-34018): cookies and proxy
  credentials do not persist. The share extension has no app group to hand a
  URL through.
- Gatekeeper quarantines it on download regardless.

Do not point users at it. The two signed channels below are the product.

## One-time account setup

1. **App IDs** (developer.apple.com > Identifiers). `org.codeberg.theoden8.webspace`
   already exists for iOS; enable the macOS platform on it, with App Groups
   and Keychain Sharing. Add `org.codeberg.theoden8.webspace.ShareExtension`
   for the extension. Both use team `7NGC2P87LM`, which
   `ios/Runner/AppGroup.swift` writes into the macOS group name. It is
   spelled out rather than taken from `$(TeamIdentifierPrefix)`, because the
   build has no team until `sign_macos.sh` signs it.
2. **App group** `group.org.codeberg.theoden8.webspace`, enabled for both IDs.
3. **Certificates**. Developer ID Application for the direct build; Apple
   Distribution plus Mac Installer Distribution for the App Store build.
4. **Provisioning profiles** (Mac App Store type) for the app and the
   extension. The Developer ID channel needs none.
5. **App Store Connect**. Add the macOS platform to the existing app record
   rather than creating a second one: the bundle identifier matches the iOS
   app, so macOS joins it as a universal purchase and inherits the listing.
   Then fill in what is per-platform: Mac screenshots (1280x800, 1440x900,
   2560x1600 or 2880x1800), the app category, and privacy labels mirroring
   the iOS ones.

## Signing locally

Write `macos/Runner/Configs/Signing.local.xcconfig` (gitignored) so Xcode
builds with a real identity:

```
WEBSPACE_TEAM_ID = 7NGC2P87LM
WEBSPACE_CODE_SIGN_IDENTITY = Apple Development
```

That is only for running a properly entitled build during development. The
release artifacts are signed after the build:

```bash
# Developer ID: hardened runtime, notarized, stapled -> build/macos/*.zip, *.dmg
fvm flutter build macos --release --dart-define=WEBSPACE_EXTENSION_SEARCH=true
NOTARY_PROFILE=webspace-notary \
  ./scripts/sign_macos.sh devid

# Mac App Store: profiles embedded, packaged -> build/macos/*.pkg
fvm flutter build macos --release
MACOS_PROVISION_PROFILE=~/profiles/app.provisionprofile \
MACOS_EXT_PROVISION_PROFILE=~/profiles/ext.provisionprofile \
  ./scripts/sign_macos.sh mas
```

The two channels are two builds from one commit, because only the Developer
ID build carries the extension search (WEBEXT-019): App Review guideline
3.2.2(i) rejects an in-app catalogue of extensions, so the search is compiled
in only with `--dart-define=WEBSPACE_EXTENSION_SEARCH=true`, and without it
none of its code is in the binary.
[scripts/check_extension_search.sh](../scripts/check_extension_search.sh)
looks for it in the built snapshot: `sign_macos.sh mas` refuses a build that
carries it, `devid` notes one that does not, and CI checks the iOS and macOS
builds it makes, which are made without the define.

`NOTARY_PROFILE` is a notarytool keychain profile, stored once with
`xcrun notarytool store-credentials webspace-notary --apple-id <id>
--team-id 7NGC2P87LM`, which asks for an app-specific password
(account.apple.com, Sign-In and Security); `NOTARY_KEY` + `NOTARY_KEY_ID` +
`NOTARY_ISSUER`, an App Store Connect API key, work instead. The script
prints the two upload commands for the `.pkg`; either `xcrun altool
--upload-app` or `fastlane deliver --platform osx` sends it to App Store
Connect.

`devid` notarizes twice: the app, through the zip, so its ticket is stapled
before the `.dmg` is built from it, then the `.dmg` itself, the file a user
downloads. Either file is a release asset.

## What the store build has to keep true

- **The sandbox stays on.** All file IO already goes through
  `FilePicker` (powerbox) or the app container, and the only sockets the app
  listens on are loopback ones, so the sandbox costs the app nothing today.
- **The signature is taken from the built bundle, not from the file.** The
  build resolves the team prefix, adds what the `ENABLE_*` settings generate
  (`com.apple.security.network.client`, without which a sandboxed browser
  loads nothing and reports nothing) and what the provisioning profile
  carries (`application-identifier`, `team-identifier`). The committed file
  has none of those, so `sign_macos.sh` reads the bundle's own entitlements,
  drops `com.apple.security.get-task-allow` (Xcode's development grant, which
  notarization and App Store Connect both reject), and fails when the file
  declares a capability the build did not grant.
- **Entitlements and `ENABLE_*` build settings agree.** Xcode merges the
  generated set with the file, so a capability granted in one and denied in
  the other half-ships. Gated by
  [test/js/macos_store_declarations.test.js](../test/js/macos_store_declarations.test.js).
- **Export compliance.** `macos/Runner/Info.plist` carries
  `ITSAppUsesNonExemptEncryption` on the same basis as iOS (EXPORT-001);
  `scripts/check_export_compliance.sh` runs before the `.pkg` is built.
- **Tor needs `network.server`.** tor's SOCKS port and each pluggable
  transport are loopback listeners, and the sandbox refuses `listen()`
  without `network.server`, loopback included: tor then exits before its
  control port opens. Every configuration grants it, with
  `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES` to match, while
  `macos/Podfile` carries the Tor pod (TOR-007, BUG-013 attempt 13). The
  integration tier builds Debug only, so Release rests on the gate in
  [test/js/macos_store_declarations.test.js](../test/js/macos_store_declarations.test.js).
- **Privacy manifests do not apply.** Apple reads `PrivacyInfo.xcprivacy` on
  iOS, iPadOS, tvOS, visionOS and watchOS only. If that changes,
  `ios/Runner/PrivacyInfo.xcprivacy` is the template.
- **Build numbers are per platform.** `CFBundleVersion` comes from the
  `pubspec.yaml` build number; under universal purchase the macOS track has
  its own history, so a macOS upload needs a number no macOS build has used.

## Passkeys need an entitlement Apple grants

WKWebView implements WebAuthn itself, and AuthenticationServices lets it
answer any site only in an app holding
`com.apple.developer.web-browser.public-key-credential` (PASSKEY-013,
PASSKEY-014 in
[openspec/specs/passkey-support/spec.md](../openspec/specs/passkey-support/spec.md)).
It is a managed capability, so the committed entitlements leave it out until
the team has it; with it named and no profile carrying it, the app does not
launch. Until then passkeys do nothing on macOS: WebKit refuses every site.

1. **Meet the criteria first.** Apple's list: the app declares the `http` and
   `https` URL schemes in `Info.plist`, offers a URL field, search, or curated
   bookmarks on launch, and navigates an opened http(s) URL straight to its
   destination. `macos/Runner/Info.plist` declares only `webspace` today, and
   `AppDelegate.application(_:open:)` ignores any other scheme, so both change
   before the request, and declaring them makes the app a default-browser
   candidate.
2. **Request it.** The account holder files
   <https://developer.apple.com/contact/request/macos-browsers-passkeys/>.
   Apple adds it to the account as a managed capability.
3. **Once granted:** enable it on the `org.codeberg.theoden8.webspace` App ID,
   regenerate the Mac App Store profile, and add
   `<key>com.apple.developer.web-browser.public-key-credential</key><true/>` to
   `Release.entitlements`. Three things follow from `sign_macos.sh`:
   - `adhoc` has to drop the key alongside the app group and keychain group,
     both in `materialize_entitlements` and in `assert_grants_present`'s
     ad-hoc exclusions, or the CI artifact is SIGKILLed at launch.
   - `devid` embeds no profile today, and a restricted entitlement needs one:
     it needs a Developer ID provisioning profile carrying the capability,
     copied to `Contents/embedded.provisionprofile` as `mas` does.
   - `mas` works unchanged once the profile carries it.
4. **Check it.** A signed build registers and signs in at
   <https://webauthn.io>; an archived site gets NotAllowedError from the block
   shim.

## Known limits to state in the listing

- The floor is macOS 11 (Big Sur). It rose from 10.15 when the embedded
  Tor runtime came to macOS (TOR-007): the `Tor` pod is a macOS 11 pod, so
  `platform :osx` and `MACOSX_DEPLOYMENT_TARGET` are 11.0 and
  `LSMinimumSystemVersion` follows them (it is
  `$(MACOSX_DEPLOYMENT_TARGET)`). The ShareExtension already required 11.0,
  so a Catalina user was getting a partial app before this.
- Per-site containers and per-site proxy need macOS 14 (probed at runtime
  by `appleOsMeetsFloor`). On 11 to 13 the app falls back to the legacy
  cookie-isolation engine, where sites sharing a base domain cannot load at
  the same time, the proxy controls are hidden, and a proxy carried in by a
  backup or QR fails closed (blank page) rather than loading over the
  device IP.
- Self-signed and unknown-CA sites fail closed. macOS 15+ WKWebView ignores
  `URLCredential(trust:)` and the system trust store is out of reach from a
  sandboxed app, so the trust prompt is skipped on Apple platforms
  (see the TLS trust prompt spec); the user installs the certificate in
  Keychain Access instead.
- The UI is the mobile one in a resizable window. The menu bar is the stock
  Flutter template and there are no keyboard shortcuts yet; nothing in review
  requires them.

## First submission checklist

1. `fvm flutter build macos --release` on a machine with the certificates,
   without `--dart-define=WEBSPACE_EXTENSION_SEARCH`.
2. `./scripts/sign_macos.sh mas` and upload the `.pkg`.
3. In App Store Connect: macOS platform added to the existing record,
   category set, privacy labels copied from iOS, Mac screenshots uploaded,
   minimum macOS version stated.
4. Answer export compliance with the EXPORT-001 basis if asked.
5. After approval, keep the Developer ID channel in step: the GitHub release
   `.dmg` and the store build come from the same commit.
