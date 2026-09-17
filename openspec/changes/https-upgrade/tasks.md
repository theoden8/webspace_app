## 1. Specify

- [x] 1.1 Write `openspec/changes/https-upgrade/specs/https-upgrade/spec.md`
  with HTTPS-001 (the upgrade), HTTPS-002 (silent fallback, remembered per host,
  never persisted), HTTPS-003 (hosts that cannot serve TLS), HTTPS-004 (the
  upgrade follows the navigation verdict) and HTTPS-005 (the global default-on
  knob plus the per-site override).
- [x] 1.2 HTTPS-006: leave `upgradeKnownHostsToHTTPS` at its default. It is
  iOS/macOS only and covers only hosts WebKit already knows are https, so it is
  narrower than HTTPS-001 on both axes and cannot serve the reported case.
- [x] 1.2b Write the tracking-protection delta: ETP-028 forces the upgrade on
  under the umbrella without making it a subordinate that only lives there.
- [x] 1.3 Add the `https-upgrade` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until archived.

## 2. The engine

- [x] 2.1 `lib/services/https_upgrade_engine.dart`: `upgradeFor`,
  `fallbackFor`, `recordUpgradeSuccess`, `recordUpgradeFailure`,
  `isKnownHttpOnly`, `reset`. Pure, no Flutter.
- [x] 2.2 `test/https_upgrade_engine_test.dart` covering every scenario above,
  including the two that are security properties rather than features: a
  failure on a URL the engine never upgraded is not a fallback, and a
  successful upgrade drops its in-flight entry so a later failure on the same
  URL string cannot read as one.

## 3. Wire it

- [x] 3.1 `lib/settings/app_prefs.dart`: register `httpsUpgradeEnabled: true`.
- [x] 3.2 `lib/web_view_model.dart`: the per-site field,
  `effectiveHttpsUpgradeEnabled` (ETP-028), `toJson`/`fromJson`, the
  `WebViewConfig`, the `launchUrlFunc` typedef and both call sites.
- [x] 3.3 `lib/main.dart` `launchUrl` signature and
  `lib/screens/inappbrowser.dart` `InAppWebViewScreen` + its `WebViewConfig`,
  completing the five-step per-site checklist in CLAUDE.md. A nested webview
  still loading plaintext while its parent upgrades is exactly the silent
  bypass that checklist exists to prevent.
- [x] 3.4 `lib/services/webview.dart`: consult the engine in
  `shouldOverrideUrlLoading` AFTER `config.shouldOverrideUrlLoading` returns
  (HTTPS-004); cancel and load the upgraded URL; on `onReceivedError` for an
  upgraded main-frame URL, load `fallbackFor`; on a successful main-frame load,
  `recordUpgradeSuccess`.
- [x] 3.5 One engine instance per process, reachable from both the root and
  nested webview paths, so a host learned http-only in one is not re-probed by
  the other.

## 4. Surface it

- [x] 4.1 A global row in app settings, default on.
- [x] 4.2 A per-site row on the Privacy screen, locked with `value: true` while
  the umbrella is on (ETP-028) and captioned like the third-party-cookies row,
  since a forced-on security control is the direction a reader does not
  predict.
- [x] 4.3 `lib/l10n/app_en.arb`: title + hint keys, with descriptions. The hint
  carries what the subtitle must not: that a site without TLS falls back on its
  own, and that turning it off means this site's traffic is readable on the
  network.
- [x] 4.4 The other 66 ARBs in their own commit, pushed with 4.3 (CLAUDE.md,
  Git).

## 5. Verify

- [x] 5.1 `test/settings_backup_test.dart` picks the new global pref up from the
  registry with no edit; re-run it.
- [x] 5.2 Covered by construction: `nested_webview_field_parity_test.dart`
  reads `LaunchUrlFunc`'s parameters and requires each to survive every step,
  so adding the field to the typedef enrolled it. `nested_webview_posture_parity`
  separately refused the new `WebViewConfig` field until it was classified.
- [x] 5.3 A browser-tier test is NOT the right place: the upgrade is a
  navigation decision, and the engine owns it. The call-site ordering
  (HTTPS-004) is gated in `test/js/page_bridge_authority.test.js` beside the
  CAPTCHA-008 ordering it copies, plus a second case requiring the loaded URL
  to be the engine's output. Both were checked against an inverted call site:
  moving the upgrade above the verdict fails the first and not the second.

## 6. Regression gates

Every gate below was checked against the mutation it exists to catch. A gate
that passes either way is worse than none, because it reads as cover.

- [x] 6.a `test/js/https_upgrade_funnel.test.js`, five properties of the
  call-site wiring that no Dart test reaches. Mutations checked: delete the
  `onReceivedError` fallback; delete `recordUpgradeSuccess`; add a second
  `HttpsUpgradeEngine()`; set `upgradeKnownHostsToHTTPS = false`; flip the
  registered default to `false`. Each fails exactly one gate.
- [x] 6.b The ordering (HTTPS-004) in `page_bridge_authority.test.js`, checked
  by moving the upgrade above the navigation verdict.
- [x] 6.c `HTTPS-005 / ETP-028 the effective decision` in
  `https_upgrade_engine_test.dart`. Mutations checked: force the umbrella the
  other way (the shape of the getter directly above it), and drop the app-wide
  default so null reads as off. The first is the one to fear: nothing else in
  the suite reads that getter, so inverting it would move a site to plaintext
  for turning privacy on, silently.

## 7. Not verified

- [ ] 7.1 **No end-to-end run.** Nothing here has driven a real webview: the
  engine is unit-tested, the wiring is gated structurally, and neither proves
  that an http navigation in a running app comes back https. The integration
  tier (`integration_test/`, headless Linux) is where that would go, and
  HTTPS-003 makes it awkward — loopback and single-label hosts are exactly the
  ones the engine refuses, so the fixture needs a resolvable name with a
  certificate.
- [x] 7.2 **A refused TLS port is now exercised for real.**
  `test/https_upgrade_network_test.dart` drives the engine over loopback
  sockets in the call site's order, so the fallback is taken on an actual
  `SocketException` rather than by a test calling `fallbackFor`, and the
  three-navigation sequencing is exercised rather than asserted a step at a
  time.
- [x] 7.3 **The stalled port is fixed and covered.** It had no error to catch,
  so nothing fell back and the page hung: the engine now carries a `deadline`
  (8s) and the call site arms a timer with it when it issues the upgrade.
  Verified against a real socket that accepts and never answers
  (`https_upgrade_network_test.dart`, 600ms deadline, falls back in well under
  a second), and gated four ways: delete the timer, drop the generation guard,
  bypass the engine, or hardcode the duration, and a gate fails for each.
- [x] 7.4 **A rejected certificate was not an unobserved case, it was a
  defect.** It does not reach `onReceivedError` on Android or Linux at all: it
  reaches `onReceivedServerTrustAuthRequest`, which prompts the user to trust
  the certificate and pins it on approval (TLS-002/007). A default-on upgrade
  therefore asked the user to vouch for a connection the app invented, about a
  URL they never typed. HTTPS-007 carves it out — cancel silently, load the
  http they asked for, record the host — in the shape of the loopback-sinkhole
  carve-out beside it. Gated three ways (remove it, move it past the prompt,
  cancel without loading the fallback) and unit-tested for the host-keyed
  reversal the platform callback forces.
- [ ] 7.5 **Still no end-to-end run**, unchanged from 7.1: everything above is
  the engine plus structural gates on the wiring. Chromium's own timing (how
  long before a stalled handshake produces an event of its own, whether the
  deadline or the platform wins the race) is device work.
