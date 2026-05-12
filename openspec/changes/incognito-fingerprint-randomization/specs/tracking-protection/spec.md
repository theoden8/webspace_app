# Enhanced Tracking Protection — incognito fingerprint randomization delta

## MODIFIED Requirements

### Requirement: ETP-004 - Per-site stability and cross-site uniqueness

The shim's randomized values SHALL be deterministic per `siteId` so a non-incognito site sees the same fingerprint across launches, but distinct seeds SHALL produce distinct shim sources so two sites differ. When the site has `incognito` set, the seed SHALL additionally mix in the per-launch nonce defined by ETP-019, so the fingerprint is stable within a single app session but randomizes across cold restarts. The shim builder itself remains a pure function of its seed string — the seed-derivation rule lives in `computeAntiFingerprintingSeed` ([lib/services/anti_fingerprinting_shim.dart](../../../../../lib/services/anti_fingerprinting_shim.dart)).

#### Scenario: Same seed reproduces the same shim

**Given** `buildAntiFingerprintingShim('seed-A')` returns string `S1`
**When** the same builder is invoked again with the same seed
**Then** the result equals `S1`

#### Scenario: Different seeds produce different shim text

**Given** `buildAntiFingerprintingShim('seed-A')` returns `S1`
**And** `buildAntiFingerprintingShim('seed-B')` returns `S2`
**Then** `S1 != S2`
**And** both contain the literal seed string for the FNV-1a hash

#### Scenario: Non-incognito seed is the siteId verbatim

**Given** `computeAntiFingerprintingSeed(siteId: 's1', incognito: false, launchNonce: 'n1')`
**Then** the returned seed equals `'s1'`
**And** `computeAntiFingerprintingSeed(siteId: 's1', incognito: false, launchNonce: 'n2')` also equals `'s1'`
(non-incognito sites see the same fingerprint across launches regardless of nonce)

#### Scenario: Incognito seed mixes in the launch nonce

**Given** `computeAntiFingerprintingSeed(siteId: 's1', incognito: true, launchNonce: 'n1')` returns `seed1`
**And** `computeAntiFingerprintingSeed(siteId: 's1', incognito: true, launchNonce: 'n2')` returns `seed2`
**Then** `seed1 != seed2`
**And** `seed1 != 's1'`
**And** both seeds embed the siteId so two incognito sites under the same nonce remain distinct

#### Scenario: Incognito seed is stable within a launch

**Given** the launch nonce is `n1` for the lifetime of the process
**When** `computeAntiFingerprintingSeed(siteId: 's1', incognito: true, launchNonce: 'n1')` is called twice within that process
**Then** both calls return the same seed
(same fingerprint across iframe re-injections, tab switches, and nested webview opens within one session)

---

## ADDED Requirements

### Requirement: ETP-019 - Per-launch nonce for incognito fingerprint randomization

The system SHALL maintain a process-lifetime random nonce, exposed as `LaunchNonce.value` in [lib/services/launch_nonce.dart](../../../../../lib/services/launch_nonce.dart). The nonce SHALL be generated lazily on first read using `dart:math` `Random.secure` and SHALL remain identical for every subsequent read within the same process. The nonce SHALL NOT be persisted to disk: a new process start (cold launch, OS-killed restore, debug hot-restart) SHALL produce a fresh nonce. App resume from background is NOT a new launch and SHALL NOT regenerate the nonce. The nonce SHALL be mixed into the anti-fingerprinting seed only when the site has `incognito: true` (per ETP-004).

#### Scenario: Stable across reads within a process

**Given** `LaunchNonce.value` returns `n` on first read
**When** `LaunchNonce.value` is read again later in the same process
**Then** the returned value equals `n`

#### Scenario: Non-empty cryptographic random

**Given** `LaunchNonce.value` is read
**Then** the returned string is non-empty
**And** matches `^[0-9a-f]+$` (hex encoding of `Random.secure` bytes)

#### Scenario: Test override

**Given** a test calls `LaunchNonce.overrideForTesting('fixed')`
**When** `LaunchNonce.value` is read
**Then** the returned value equals `'fixed'`
**And** a subsequent `LaunchNonce.resetForTesting()` causes the next read to regenerate a fresh random nonce

#### Scenario: Incognito + Tracking Protection randomizes per launch

**Given** a site has `incognito: true` and `trackingProtectionEnabled: true`
**When** the webview is constructed
**Then** the seed passed to `buildAntiFingerprintingShim` is `'${siteId}:${LaunchNonce.value}'`
**And** after a process restart the seed embeds a different nonce
**And** therefore the shim source (and every fingerprintable surface seeded by the PRNG) changes across launches

#### Scenario: Non-incognito site keeps stable per-site fingerprint

**Given** a site has `incognito: false` and `trackingProtectionEnabled: true`
**When** the webview is constructed
**Then** the seed passed to `buildAntiFingerprintingShim` is `siteId` verbatim
**And** the fingerprint is identical across launches (ETP-004 baseline preserved)
