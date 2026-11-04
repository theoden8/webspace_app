# Legal Specification

## Purpose

Two positions the project has to keep true as code changes: the App Store
encryption declaration, and the licences of the shipped work. The app's own
code is MIT, except `go/hiddenkey` (BSD-3-Clause). The artwork is under
`assets/LICENSE` (CC BY-NC-SA 4.0), which stays as it is.

## Status

- **Status**: Completed
- **Platforms**: iOS and macOS (declaration), all (the rest)

---

## Requirements

### Requirement: EXPORT-001 - Encryption declaration

The iOS and macOS bundles SHALL each declare `ITSAppUsesNonExemptEncryption`
as `false` and SHALL NOT carry an `ITSEncryptionExportComplianceCode`. Both
ship the same code from the same source, so they answer the question the same
way; a macOS bundle that omits the key stalls its own submission.

Basis: the source is published under a licence permitting further
dissemination, so the object code is not subject to the EAR (note to
15 CFR 734.3(b)(3), criteria in 15 CFR 742.15(b)(1)). This rests on
EXPORT-002 and EXPORT-003; revisit it if either stops holding.

**Exempt is not "no encryption".** The app implements AES-GCM-256, Argon2id,
HKDF-SHA-256 and HMAC-SHA-256 in
[archive_crypto.dart](../../../lib/services/archive_crypto.dart), AES-GCM over the
stores kept at rest in
[keychain_aead.dart](../../../lib/services/keychain_aead.dart), X25519 key
pairs hidden by Elligator 2 for obfs4's handshake in
[go/hiddenkey](../../../go/hiddenkey/README.md) (the Apple builds' bridge
transports), and links tor's TLS and OpenSSL. Apple's OS-provided and authentication-only
exemptions describe none of that. Reasoning from *those* exemptions is what
led #344 to flip the key to `true`; they were never the basis here.

**No notification is owed, and it turns on one term.** 15 CFR 742.15(b)(2)
requires emailing the source location to BIS and the ENC Encryption Request
Coordinator, but only for source code that "provides or performs
*non-standard cryptography*" — an EAR term of art for proprietary or
unpublished algorithms. EXPORT-002 confines the app to published standards
(FIPS 197, NIST SP 800-38D, RFC 9106, RFC 5869, RFC 2104, RFC 8446,
RFC 7748/8032, RFC 9380), so 742.15(b)(2) does not reach it and there is nothing to
file. This is the whole reason the app owes no paperwork despite shipping a
lot of cryptography, and it is the first thing to re-check when EXPORT-002
is amended.

**Tor is the near miss, and it clears.** 15 CFR 772.1 defines non-standard
cryptography as functionality "that ha[s] not been adopted or approved by a
duly recognized international standards body (e.g., IEEE, IETF, ISO, ITU,
ETSI, 3GPP, TIA, and GSMA) **and** ha[s] not otherwise been published". Tor's
circuit protocol and ntor handshake are not IETF standards, so the first limb
is met. The second is not: the protocol is published in full at
spec.torproject.org, the implementation is open source, and the primitives
under it are AES, SHA-2, Curve25519 (RFC 7748), Ed25519 (RFC 8032) and TLS
(RFC 8446). The test is conjunctive, so an unratified but published protocol
is not non-standard cryptography. A future component that is *unpublished*
fails on the second limb no matter how standard its primitives are, and that
is the case to watch for.

**The Apple builds' bridge transports clear the same way.** IPtProxy's
transports are published protocols with published source, over published
primitives:

| Transport | Protocol | Primitives |
|---|---|---|
| obfs4 | lyrebird's `doc/obfs4-spec.txt` | X25519 with Elligator 2 (RFC 7748, RFC 9380), HMAC-SHA-256, SipHash-2-4, XSalsa20-Poly1305 |
| snowflake | the Snowflake paper and its source | WebRTC's DTLS (RFC 6347) |
| webtunnel | HTTPS | TLS (RFC 8446) |
| dnstt | its published design | the Noise framework's `Noise_NK_25519_ChaChaPoly_BLAKE2s` (RFC 7748, RFC 8439, RFC 7693) |

**`true` is not the cautious alternative.** It obliges an
`ITSEncryptionExportComplianceCode`, which Apple issues only after approving
uploaded documentation; for standard algorithms that documentation is the
French ANSSI declaration, required when distributing in France and reported
to take one to two months. Until the code exists every upload is rejected as
ITMS-90592, which is how #344 blocked releases.
[scripts/check_export_compliance.sh](../../../scripts/check_export_compliance.sh)
gates the two keys against each other on the fastlane deploy lanes.

#### Scenario: Key present

- **GIVEN** `ios/Runner/Info.plist` or `macos/Runner/Info.plist`
- **THEN** `ITSAppUsesNonExemptEncryption` is `false`
- **AND** no `ITSEncryptionExportComplianceCode` is present

#### Scenario: A change introduces a non-standard algorithm

- **GIVEN** a proprietary or unpublished cryptographic algorithm is added,
  contrary to EXPORT-002
- **THEN** the 15 CFR 742.15(b)(2) notification naming the source location is
  sent to BIS and the ENC Encryption Request Coordinator before release
- **AND** the date it was sent is recorded in this requirement

---

### Requirement: EXPORT-002 - Standard primitives only

Cryptography the app implements itself SHALL use published standard
primitives: AES-GCM, HMAC-SHA-256, HKDF-SHA-256, Argon2id, X25519
(RFC 7748) and Elligator 2 on Curve25519 (RFC 9380).

#### Scenario: A feature adds encryption, key derivation, or a MAC

- **THEN** it uses a primitive named above
- **AND** the construction is written down in the spec that owns it (the
  archive's is ARCH-002; obfs4's key hiding is TOR-016's, its wire format
  in `go/hiddenkey/README.md`)

---

### Requirement: EXPORT-003 - Source correspondence

A released binary SHALL be buildable from the published source.

#### Scenario: Release with a git dependency

- **GIVEN** a tagged release
- **WHEN** `dependency_overrides` name a git source
- **THEN** each is pinned to a tag or commit in a public repository

---

### Requirement: LICENSE-001 - No copyleft code in a shipped binary

No GPL or AGPL code SHALL be built, linked or bundled into a distributed
artifact, whatever brings it in: a pub package, a crate, a pod, a Gradle
dependency, or a download in a build script, the app's or a plugin's. LGPL
code SHALL ship only as a shared library the user can replace: a system
library, or one a package bundles as LICENSE-004 asks.

[`licences.tsv`](licences.tsv) is the policy: each licence a component may
ship under and how. Its one exception is `desugar_jdk_libs`, under GPL-2.0
with the Classpath Exception, which the notification plugin requires on
Android and whose exception permits linking it. A component's licence is
read from what it ships, the code it bundles included, and every component
a build file pulls in outside pub and Cargo has a row in
[`components.tsv`](components.tsv) saying what it was read from.

#### Scenario: New dependency

- **WHEN** a dependency is added to `pubspec.yaml`, a Cargo manifest, a
  Podfile, a Gradle file or a build script
- **THEN** `test/js/licence_policy.test.js` (pub packages, pods, Gradle,
  downloads) or `rust/webspace_adblock/build.rs` (crates, and the tracker
  surrogates it downloads, by their `components.tsv` row) fails until its
  licence, read from its source, is one `licences.tsv` allows for how it
  ships

#### Scenario: A build pulls in what no build file names

- **WHEN** a build links or ships a component that only the built output
  shows: a Maven artifact Gradle resolves, a library the Linux bundle or the
  snap copies in, the code a prebuilt Tor framework was configured with
- **THEN** CI fails after that build: `tool/check_maven_licences.js` on every
  artifact the release runtime classpaths resolve, read from its POM;
  `tool/check_bundle_licences.js` on every Debian copyright file the Linux
  bundle or the snap carries, and on any GNU notice outside them;
  `scripts/verify_tor_framework.sh` on a framework that links the GPL-only
  parts of tor

#### Scenario: A build root keeps a library's debug sources

- **WHEN** a built root holds a library's sources under
  `lib/debug/source/<library>/`, as flatpak-builder leaves them for the
  `.Debug` extension a bundle leaves out
- **THEN** a file there carrying a GNU notice passes
  `tool/check_bundle_licences.js` only when every GNU licence it names is the
  Lesser or Library GPL and the library's copyright file in the same root
  (`share/doc/<library>/copyright` or `usr/share/doc/<library>/copyright`)
  names an LGPL
- **AND** a GPL notice there, or one in a library whose notices name no LGPL,
  still fails (`test/js/bundle_licences.test.js`)

#### Scenario: A Go module is compiled into the bridge transports

- **WHEN** `go/iptproxy/build.sh` links a Go module into IPtProxy.xcframework,
  or into the lyrebird the Linux bundle ships beside tor (`build.sh
  lyrebird`, which `linux/tor.cmake` runs)
- **THEN** `build.sh check`, which lists both, fails unless the module has a
  row in `go/iptproxy/licences.tsv` with its licence read from its licence
  files, and `test/js/licence_policy.test.js` fails unless `licences.tsv` lets
  that licence link
- **AND** `scripts/verify_tor_shipped.sh` fails, through `build.sh
  check-lyrebird`, on a bundled lyrebird that `go version -m` shows compiling
  a module `licences.tsv` lacks, that names a GPL package of lyrebird's or not
  hiddenkey's and go/meekutls's, or whose `lib/tor/docs/lyrebird.txt` lacks
  a module's licence files
- **AND** a GPL file in a module is deleted before anything reads the tree,
  and what the rest of the module needs of it is our own: lyrebird's
  `internal/x25519ell2` comes from `go/hiddenkey`, and its meek_lite's
  `transports/meeklite/transport.go` from `go/meekutls/meekutls.go`, adapted
  from meek's CC0 code without reading the GPL file (`go/meekutls/PROVENANCE.md`)
- **AND** `build.sh check` fails while `transport.go` is in the tree, while
  meek_lite is built without `go/meekutls`'s file, and on a framework that
  does not carry its round tripper

#### Scenario: A component moves to another version

- **WHEN** a pod, a pub package or a download changes version
- **THEN** its row in `components.tsv` is stale and the gate fails until its
  licence is read again at the new version

#### Scenario: A package bundles code under another licence

- **WHEN** a file a pub package builds into the app carries an SPDX tag, a
  licence file or a GNU licence notice that `licences.tsv` does not allow
- **THEN** the gate fails naming the file, whatever licence the package
  states for itself

---

### Requirement: LICENSE-002 - Copyleft data stays runtime-fetched

Filter lists, blocklists, rules and tiles under GPL/LGPL/CC BY-SA/ODbL SHALL
be downloaded at runtime and cached on-device. They SHALL NOT be committed to
this repo or bundled into a release artifact.

#### Scenario: A blocking feature needs list data

- **THEN** the service fetches it from upstream at runtime
- **AND** no copy of the list enters `assets/` or the APK/IPA

#### Scenario: A dependency offers to bundle the data

- **GIVEN** a pod or package ships copyleft data as an optional part, such as
  Tor.framework's `Tor/GeoIP` subspec (IPFire Location Database, CC BY-SA 4.0)
- **THEN** that part is not used, and the device fetches the data at runtime
  instead (TOR-014)
- **AND** a structural test fails CI if the part is named in a build file
  (`test/js/tor_geoip_not_bundled.test.js`)

---

### Requirement: LICENSE-003 - Attribution is collected, not hand-written

Attribution SHALL come from dependency metadata at build time, and the
licences page (`lib/services/licenses.dart`) SHALL show every notice it
collects:

| Graph | Collector |
|---|---|
| pub packages | `LicenseRegistry`, which reads each package's root `LICENSE` |
| Rust crates | the adblock build's blob: each linked crate's licence files, or its SPDX text where it ships none; and the licence file of the tracker surrogates the build takes in for its `$redirect=` pool (CB-010), under the licence their `components.tsv` row reads |
| pods (iOS, macOS) | CocoaPods' acknowledgements, copied by each Podfile's `post_integrate` into `assets/native_notices/pods.md` |
| Maven artifacts (Android) | `android/app/maven_licences.gradle`, into `assets/native_notices/maven.json` |

Licence texts SHALL NOT be copied into the repo for anything a collector
reaches. `assets/licenses/` covers only what none sees: runtime-downloaded
data, vendored or modified source, a notice a pub package nests below its
root `LICENSE` (listed in [`attributions.tsv`](attributions.tsv)), and
components that are not a package in any graph.

A library a Linux package builds from source and bundles (WPE WebKit and
libwpe in the snap and the flatpak) SHALL carry its notices in the package as
a Debian package does: `usr/share/doc/<name>/copyright` naming its source and
revision and every licence of its tree, every licence file of that tree, the
text of an LGPL or Apache-2.0 it names that the tree does not carry, a
permission notice that lives only in a source file's header (an X11-style
notice asks to appear in the documentation), and the copyright lines of its
sources beside it, written at build time by `linux/install_notices.sh`. The
licences page SHALL list every such notice the package carries, so the app's
own notices name the libraries LGPL-2.1 section 6 asks them to.

#### Scenario: A library's licence lives in a header or nowhere in its tree

- **WHEN** `linux/install_notices.sh` writes a copyright file whose licence
  names an LGPL or Apache-2.0 and no licence file of the tree is its text
- **THEN** it fails unless `--licence-text` gives the build host's copy, and
  it refuses a `--licence-text` that is missing, is the text of neither, is the
  text of one the licence does not name, or would replace a licence file of
  the tree
- **AND** `--notice-of` copies a tree file's first block comment that names a
  copyright, as it is, beside the notices, and refuses a path outside the tree,
  a file the tree lacks, and a file whose comments name no copyright or whose
  notice names no licence (`test/js/source_offer.test.js`)

#### Scenario: New pub package or crate

- **THEN** nothing is added by hand; the licence page picks it up

#### Scenario: A Linux package bundles a library it builds

- **WHEN** the snap or the flatpak builds a library from source and ships it
- **THEN** its notices are in `usr/share/doc/<name>/` of the package and on
  the licences page

#### Scenario: New data source or vendored tree

- **THEN** its licence text is bundled under `assets/licenses/` and registered
  in `lib/services/licenses.dart`, and `test/licenses_test.dart` fails on a
  text the page does not show

#### Scenario: A pub package nests a notice below its root licence

- **WHEN** a package ships code under a notice of its own (a vendored
  library, a ported algorithm) that its root `LICENSE` does not hold
- **THEN** `test/js/licence_policy.test.js` fails until `attributions.tsv`
  names a text under `assets/licenses/` that carries it

---

### Requirement: LICENSE-004 - A bundled LGPL library ships as the LGPL asks

A library under the LGPL that a package bundles instead of taking it from the
system SHALL ship as LGPL-2.1 section 6 asks. The snap bundles two: WPE WebKit,
and libwpe, whose `src/key-unicode.c` (adapted from GDK's `gdkkeyuni.c`) is
under the LGPL, version 2 or later; the rest of its tree is under its
BSD-2-Clause `COPYING`, Apache-2.0 (`src/gamepad.c`, `include/wpe/gamepad.h`)
and the X11-style notices of `include/wpe/keysyms.h`, The Open Group's
(`MIT-open-group`) and Digital's (`HPND`).

- **Replaceable:** a shared library of its own that the app loads at run time,
  so a user can put a modified build in its place; never linked into the app
  or a plugin.
- **Notices:** its licence and copyright notices in the package and on the
  licences page (LICENSE-003), with the text of the LGPL it is under: its
  tree's, or the build host's where the tree names the LGPL only in a source
  file's header, as libwpe's does.
- **Source:** its copyright file names the source, the commit built and
  anything the build changed in it first, and carries a written offer, valid
  for at least three years, of a complete machine-readable copy of that source
  for no more than the cost of making it.
- **Providable:** Software Heritage, which keeps what it archives, holds that
  commit and its tree, so the copy can be given for as long as the offer runs,
  whatever happens to the upstream repository.

Answering a request is the maintainers' duty, which no check holds (rung 6):
fetch the commit's tree from Software Heritage, or upstream while it serves
it. Attaching the source to each release that ships the library would lift it
to a check.

#### Scenario: The snap bundles WebKit

- **WHEN** the snap is built and installed
- **THEN** `libWPEWebKit-2.0.so` is a file of its own in the snap and a library
  of the app's names it as `NEEDED` (`scripts/check_snap.sh`)
- **AND** `usr/share/doc/wpewebkit/copyright` names WebKit's source and
  commit and carries the offer (`test/js/snap_manifest.test.js`)
- **AND** Software Heritage holds that commit and its tree, asked about the
  installed snap's own copyright file (`tool/check_source_offer.js`)

#### Scenario: The snap bundles libwpe

- **WHEN** the snap is built and installed
- **THEN** `libwpe-1.0.so` is a file of its own in the snap and a library of
  the snap names it as `NEEDED` (`scripts/check_snap.sh`)
- **AND** libwpe is built from git at the commit its 1.16.3 tag names, and
  `usr/share/doc/libwpe/copyright` names that source and commit, every licence
  of its tree, and carries the offer, with the build host's LGPL-2 and
  Apache-2.0 texts and keysyms.h's notice in `licences/`
  (`test/js/snap_manifest.test.js`)
- **AND** each library's notices name the licences its row in
  `components.tsv` was read as, no more and no fewer
  (`test/js/snap_manifest.test.js`)
- **AND** Software Heritage holds that commit and its tree
  (`tool/check_source_offer.js`, which asks about every copyright file that
  makes the offer)

#### Scenario: WebKit's pin moves to a commit the archive does not hold yet

- **WHEN** the snap is built from a commit Software Heritage has not archived
- **THEN** the snap job fails, naming the commit and where to ask Software
  Heritage to archive it, until the archive holds it
- **AND** `linux/install_notices.sh` refuses an offer whose revision is not a
  commit, since a branch or tag moves (`test/js/source_offer.test.js`)
