# Legal Specification

## Purpose

Two positions the project has to keep true as code changes: the App Store
encryption declaration, and MIT as the licence of the shipped work.

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
[keychain_aead.dart](../../../lib/services/keychain_aead.dart), and
links tor's TLS and OpenSSL. Apple's OS-provided and authentication-only
exemptions describe none of that. Reasoning from *those* exemptions is what
led #344 to flip the key to `true`; they were never the basis here.

**No notification is owed, and it turns on one term.** 15 CFR 742.15(b)(2)
requires emailing the source location to BIS and the ENC Encryption Request
Coordinator, but only for source code that "provides or performs
*non-standard cryptography*" — an EAR term of art for proprietary or
unpublished algorithms. EXPORT-002 confines the app to published standards
(FIPS 197, NIST SP 800-38D, RFC 9106, RFC 5869, RFC 2104, RFC 8446,
RFC 7748/8032), so 742.15(b)(2) does not reach it and there is nothing to
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
primitives: AES-GCM, HMAC-SHA-256, HKDF-SHA-256, Argon2id.

#### Scenario: A feature adds encryption, key derivation, or a MAC

- **THEN** it uses a primitive named above
- **AND** the construction is written down in the spec that owns it (the
  archive's is ARCH-002)

---

### Requirement: EXPORT-003 - Source correspondence

A released binary SHALL be buildable from the published source.

#### Scenario: Release with a git dependency

- **GIVEN** a tagged release
- **WHEN** `dependency_overrides` name a git source
- **THEN** each is pinned to a tag or commit in a public repository

---

### Requirement: LICENSE-001 - No copyleft code in a shipped binary

No GPL/AGPL code SHALL be linked into a distributed artifact. LGPL code
SHALL ship only as a shared library the user can replace: a system library,
or one a package bundles as LICENSE-004 asks.

#### Scenario: New dependency

- **WHEN** a dependency is added to `pubspec.yaml`, a Cargo manifest, or a
  platform build file
- **THEN** its licence is permissive or file-level copyleft (MIT, BSD,
  Apache-2.0, MPL-2.0), or it is LGPL code that ships as a replaceable
  shared library

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

Attribution SHALL come from dependency metadata at build time: pub packages
through `LicenseRegistry`, Rust crates through the SPDX blob the adblock build
emits. Licence texts SHALL NOT be copied into the repo for anything either
collector reaches.

`assets/licenses/` covers only what they cannot see: runtime-downloaded data,
vendored or modified source, and components that are not a package in either
graph.

A library a Linux package builds from source and bundles (WPE WebKit and
libwpe in the snap and the flatpak) SHALL carry its notices in the package as
a Debian package does: `usr/share/doc/<name>/copyright` naming its source and
revision and its licence, every licence file of its source tree and the
copyright lines of its sources beside it, written at build time by
`linux/install_notices.sh`. The licences page SHALL list every such notice the package carries, so the
app's own notices name the libraries LGPL-2.1 section 6 asks them to.

#### Scenario: New pub package or crate

- **THEN** nothing is added by hand; the licence page picks it up

#### Scenario: A Linux package bundles a library it builds

- **WHEN** the snap or the flatpak builds a library from source and ships it
- **THEN** its notices are in `usr/share/doc/<name>/` of the package and on
  the licences page

#### Scenario: New data source or vendored tree

- **THEN** its licence text is bundled under `assets/licenses/` and registered
  in the custom-licence list in `lib/main.dart`

---

### LICENSE-004 - A bundled LGPL library ships as the LGPL asks

A library under the LGPL that a package bundles instead of taking it from the
system (WPE WebKit in the snap) SHALL ship as LGPL-2.1 section 6 asks:

- **Replaceable:** a shared library of its own that the app loads at run time,
  so a user can put a modified build in its place; never linked into the app
  or a plugin.
- **Notices:** its licence and copyright notices in the package and on the
  licences page (LICENSE-003).
- **Source:** its copyright file names the source, the commit built and
  anything the build changed in it first, and carries a written offer, valid for at least three years, of a complete
  machine-readable copy of that source for no more than the cost of making it.
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

#### Scenario: WebKit's pin moves to a commit the archive does not hold yet

- **WHEN** the snap is built from a commit Software Heritage has not archived
- **THEN** the snap job fails, naming the commit and where to ask Software
  Heritage to archive it, until the archive holds it
- **AND** `linux/install_notices.sh` refuses an offer whose revision is not a
  commit, since a branch or tag moves (`test/js/source_offer.test.js`)
