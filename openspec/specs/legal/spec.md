# Legal Specification

## Purpose

Two positions the project has to keep true as code changes: the App Store
encryption declaration, and MIT as the licence of the shipped work.

## Status

- **Status**: Completed
- **Platforms**: iOS (declaration), all (the rest)

---

## Requirements

### EXPORT-001 - Encryption declaration

The iOS bundle SHALL declare `ITSAppUsesNonExemptEncryption` as `false`.

Basis: the source is published under a licence permitting further
dissemination, so the object code is not subject to the EAR (note to
15 CFR 734.3(b)(3), criteria in 15 CFR 742.15(b)). This rests on EXPORT-002
and EXPORT-003; revisit it if either stops holding.

#### Scenario: Key present

- **GIVEN** `ios/Runner/Info.plist`
- **THEN** `ITSAppUsesNonExemptEncryption` is `false`

---

### EXPORT-002 - Standard primitives only

Cryptography the app implements itself SHALL use published standard
primitives: AES-GCM, HMAC-SHA-256, HKDF-SHA-256, Argon2id.

#### Scenario: A feature adds encryption, key derivation, or a MAC

- **THEN** it uses a primitive named above
- **AND** the construction is written down in the spec that owns it (the
  archive's is ARCH-002)

---

### EXPORT-003 - Source correspondence

A released binary SHALL be buildable from the published source.

#### Scenario: Release with a git dependency

- **GIVEN** a tagged release
- **WHEN** `dependency_overrides` name a git source
- **THEN** each is pinned to a tag or commit in a public repository

---

### LICENSE-001 - No copyleft code in a shipped binary

No GPL/AGPL code SHALL be linked into a distributed artifact. LGPL
components SHALL be dynamically linked system libraries only.

#### Scenario: New dependency

- **WHEN** a dependency is added to `pubspec.yaml`, a Cargo manifest, or a
  platform build file
- **THEN** its licence is permissive or file-level copyleft (MIT, BSD,
  Apache-2.0, MPL-2.0), or it is a dynamically linked LGPL system library

---

### LICENSE-002 - Copyleft data stays runtime-fetched

Filter lists, blocklists, rules and tiles under GPL/LGPL/CC BY-SA/ODbL SHALL
be downloaded at runtime and cached on-device. They SHALL NOT be committed to
this repo or bundled into a release artifact.

#### Scenario: A blocking feature needs list data

- **THEN** the service fetches it from upstream at runtime
- **AND** no copy of the list enters `assets/` or the APK/IPA

---

### LICENSE-003 - Attribution is collected, not hand-written

Attribution SHALL come from dependency metadata at build time: pub packages
through `LicenseRegistry`, Rust crates through the SPDX blob the adblock build
emits. Licence texts SHALL NOT be copied into the repo for anything either
collector reaches.

`assets/licenses/` covers only what they cannot see: runtime-downloaded data,
vendored or modified source, and components that are not a package in either
graph.

#### Scenario: New pub package or crate

- **THEN** nothing is added by hand; the licence page picks it up

#### Scenario: New data source or vendored tree

- **THEN** its licence text is bundled under `assets/licenses/` and registered
  in the custom-licence list in `lib/main.dart`
- **AND** the README License section names it
