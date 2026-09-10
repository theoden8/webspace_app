# Security reviews (`docs/security/`)

Whole-app security reviews are expensive (the 2026-09 run read every bridge, shim,
engine and native entry point, then adversarially re-verified 44 candidate findings).
Each run is persisted here so the next one starts from what is already known instead
of re-auditing the whole surface.

## Files

- `NNNN-MM-DD-review.md`: one file per run. Findings carry a stable id `SEC-NNN`
  (never reused), a severity, a verification confidence, the exact `file:line`,
  the spec requirement they contradict, and a fix that keeps the user experience
  intact. A **Verified safe** section lists the paths that were checked and hold,
  with the line that makes them hold, so a later run can skip them.
- Findings are closed by editing the run file's status column, not by deleting the
  row. Cite the fixing commit or PR. A finding that resurfaces through a new code
  path is a recurring bug: open a `docs/bugs/NNN-*.md` file and link it from here.

## How a run is done

The method mirrors the layered pipeline in `formal/README.md`: one reviewer per
attack surface, then one independent verifier per candidate finding, then only
verified findings are reported.

1. **Partition by attack surface**, not by directory. The 2026-09 slices were:
   URL handling and nested-webview config propagation; page-to-native bridges
   (every `addJavaScriptHandler` and native webview callback); injected JS shims;
   crypto, secret storage and backup import/export; network, TLS, proxy and
   downloads; Android native; Apple and Linux native; the isolation engines and
   archive tiering. Each reviewer gets the threat model below, the spec ids for its
   slice, and a list of concrete things to hunt for.
2. **Verify every candidate independently.** A second reader re-derives the finding
   from source without trusting the description, checks it against the hard
   exclusions (DoS, secured-on-disk secrets, hardening wishes, theoretical races,
   log spoofing, documented accepted gaps), and scores confidence 1 to 10.
   Findings below 8 go to the appendix, not the main list.
3. **Report only what survived**, with the verifier's corrected severity and the
   minimal UX-preserving fix. Data-loss bugs found on the way are reported in their
   own section, labelled as not attacker-triggerable.

## Threat model the reviews use

The app's stated promises define what counts as a finding:

- Sites cannot read or affect each other's cookies, storage, identity or
  fingerprint seed (per-site-containers, per-site-cookie-isolation,
  tracking-protection ETP-004/ETP-022).
- A site the user put behind a proxy or Tor never loads direct, from any code path
  (ip-leakage LEAK-003, proxy PROXY-008/PROXY-011, tor-proxy TOR-008).
- A `real` camera, microphone or location grant belongs to the origin that was
  named in the prompt; frames, popups and nested webviews do not inherit it
  (web-camera-access CAM-005/CAM-014, web-microphone-access MIC-005/MIC-014).
- Secrets never reach plaintext prefs, exports, QR codes, logs or page JS
  (proxy-password-secure-storage, settings-backup BACKUP-011).
- App-tier state is byte-identical whether or not closed archives exist
  (archive ARCH-001), and archive-tier sites leave no per-`siteId` residue
  (ARCH-006/ARCH-007).
- Untrusted input (backup JSON, QR, share intent, deep link, imported HTML) cannot
  change a privacy posture without the review dialog naming the change
  (site-settings-qr QR-008, settings-backup BACKUP-006).

Attackers, in order of how often they turned up: a hostile page (main frame, any
cross-origin iframe, worker, popup, nested webview); a crafted import file or link;
another app on the device; an on-path network attacker; someone holding the
device's plaintext storage.

## Recurring shapes worth checking first next time

Most 2026-09 findings were one of four shapes. Grep for these before anything else:

- **Raw field where the effective getter belongs**: `model.incognito`,
  `proxySettings.type == ProxyType.TOR`, `cameraMode` passed where
  `effectiveIncognito`, `resolveEffectiveProxy(...)`, `effectiveCameraMode` was
  meant. `test/js/effective_getter_boundary.test.js` only scans
  `lib/web_view_model.dart`; the misses were in `lib/main.dart`.
- **A frame-blind bridge next to a frame-aware one**: handlers registered with
  the plain `(args)` callback beside siblings that take
  `JavaScriptHandlerFunctionData` and check `isMainFrame`
  (`test/js/page_bridge_authority.test.js` gates only the ones already fixed).
- **A second entry point that skips the gate the first one has**: the QR deep link
  has a review dialog, the HTML share does not; `launchUrlFunc` passes every
  per-site field, `_executeOpenNested` and the URL bar do not; the ordering fix
  for iOS Tor was not mirrored on the Android proxy override.
- **A review that parses looser than the apply path**: the QR review tests
  `type is int`, the model decoder accepts `"1"`.
