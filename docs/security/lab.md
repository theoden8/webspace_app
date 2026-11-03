# Adversarial evaluation lab and the access policy it tests

A design and a staged plan, not an implementation. It asks one question: can an
adaptive agent that controls a hostile website steal synthetic user data from
WebSpace, or use authority the user granted to another site? Each answer is tied
to a rule of the policy below and to the component that enforces that rule.

A pass is evidence against the attacks that were tried. It does not show that no
attack exists, and nothing here is a formal proof.

Inputs: [README.md](README.md) (method and threat model),
[2026-10-28-review.md](2026-10-28-review.md) (SEC-029 to SEC-043), and the
assurance note that came with this request. The 2026-11-02 review it cites
(SEC-044, archive identity collisions) is not in this repository yet; its
findings are referred to by id only.

## 1. The policy

### Subjects

| Subject | What identifies it | Who supplies it | Never from |
|---|---|---|---|
| Site | `SiteId`, and the container it binds: `ws-<ContainerKey>`, an archive-tier site's key an HMAC of the archive key | the model, at build (`SitePosture.siteId`, `container`) | the page (NOTIF-010 drops a page-supplied `siteId`) |
| Surface | the site's webview, a nested screen, a popup, a hosted tab (LIR-034), a headless wake check | the host, at build | the page |
| Origin | `scheme://host[:port]` of the calling document | the platform: the bridge preamble's `origin`, a permission request's `origin` | a handler's arguments |
| Frame | top document or subframe | the bridge preamble's `isMainFrame` | the page |
| Document generation | one load of one webview | `PagePhases` / `PageScope`, `ViewKey` of `controller.platform` | a counter the page can read |
| Standing | own, embedded or foreign: where an origin stands toward the site (PERM-001) | `SiteOrigins`, from the site's scheme and domain claims | the page |

A site's own documents are those whose scheme is its address's and whose host
one of its domain claims covers (`SiteOrigins.owns`). Every other document a
surface of the site shows is foreign to it, however it got there.

### Objects

| Object | Where it lives | Isolated by |
|---|---|---|
| Cookies | the site's container; one shared jar in legacy mode | the engine's container; in legacy mode the jar swap (capture, clear, restore) |
| localStorage, IndexedDB, service workers, HTTP cache | the site's container | **the container only.** Legacy mode shares them across every site (per-site-containers spec, the legacy section) |
| HTTP auth credentials | `HttpAuthSession` per site, by host and realm | the app |
| Proxy passwords, keychain secrets | `SecureJsonStore` per site | the OS keystore and the app |
| Passkeys | the platform's credential provider | the provider, on the origin the app asserts (PASSKEY-004) |
| Picked media (virtual camera, mic, screen) | the site's grant record | the app (PERM-001) |
| Device capabilities: camera, mic, screen, location, notifications, background audio, protected content | the site's grants and settings | the app at the bridge, then the OS permission |
| Imported settings: backup JSON, archive sections, QR | the import path | the import sanitizer, then a consent dialog |
| Downloads | `DownloadsService`, global task ids | the app |
| Network route: per-site proxy, process route, Tor circuit | `SitePosture.container.proxy`, `ProcessRoute`, `TorTag` | the app and the native proxy rule |
| TLS trust pins | app-wide `(host, port, sha256)` | the app |

### Actions and rules

Default deny: a request no rule allows is refused. Complete mediation: every
request passes one check at the component that owns the object, never at a
reader of it.

| Rule | Allowed | Enforced at | Check today |
|---|---|---|---|
| R1 storage | a document reads and writes only its own origin's storage, in its site's container | the engine (same-origin policy), the container binding | `settings_seam_test` (container id reaches the engine); no real-engine cross-site test |
| R2 grants | a capability grant serves only the site's own documents; a foreign document is asked for itself, and its answer stays with its origin | `GrantStore`, `PageHandlers.requesterOf` | PERM-001 tests, `page_bridge_authority` gates |
| R3 frames | a cross-origin frame inside the site's own document gets no device grant and no live location; the site's device-free answers only | the same | CAM-014, MIC-016, LOC-011 |
| R4 identity | nothing the page passes names a site, origin, frame or tab | every bridge handler | `page_bridge_authority` |
| R5 documents | a result decided for one document lands in that document only | `PageScope`, `ViewKey` | US-007, SEC-029 |
| R6 surfaces | a share, a capture or a prompt ends when its document, view or site leaves the screen | `ScreenShare`, `isSiteActive` | SHARE-018, CAM-011 |
| R7 import | an imported file creates no authority: no `real` grant, no enabled script, no live location, no notification permission without a fresh local consent | the import sanitizer, `BackupController` | BACKUP-015; **not** archive sections (SEC-041) |
| R8 identity uniqueness | two site records never share a container | id minting, the import and archive open paths | backup dedupe within one file; **not** against device or archive ids (SEC-044) |
| R9 routes | a site behind a proxy or Tor never loads direct, nor on another site's route | `ProcessRoute`, the native rule | LEAK-003, PROXY-008, `proxy_router_attribution_test` |
| R10 navigation | a frame cannot steer the top document; a gesture-less cross-domain hop is refused; a popup kind is decided by the app, not the page | `NavigationDecisionEngine`, `onCreateWindow` | NESTED-013; captcha classification matches any `googleapis.com` host (SEC-042) |

The asynchronous cases follow from R2 and R5:
- **A prompt answered after a navigation** serves the origin it named, never the document that replaced it.
- **A redirect, a popup or a worker** carries no standing of its own. Its origin, read from the platform, decides it.
- **Revocation and disposal** end the grant at the store, which every later request reads.

### Where each layer helps

| Layer | Separates | Cannot separate |
|---|---|---|
| OS mandatory access control (SELinux on Android, the App Sandbox on Apple, AppArmor or a Flatpak/snap profile on Linux) | the app from other apps and the system; on Android the WebView renderer runs in a separate, more confined domain | one site from another: every site runs under the app's one identity, so the OS sees one subject |
| The engine (WebKit, Chromium) | origins, by the same-origin policy; containers, where the engine has them | anything the app hands across, through a bridge, a shared container or a shared jar |
| The app | sites, surfaces and standings, at its bridge, grant store, navigation and import paths | a compromised renderer, which this lab does not model |

The FreeBSD MAC framework and SELinux are the model for the app's part: label
every subject and object, and route every access through one check that reads
the labels (`mac_check_*`, type enforcement). Here the labels are (site,
surface, origin, frame, document), and the checks are the owners above.

Access control is not at-rest encryption. fscrypt, the archive's Argon2id and
AEAD, and the keychain protect data from someone reading the device offline.
None of them stops code running inside the app from reading what it holds, and
an open archive's sites are as reachable as any other. A different site id does
not imply separate storage either:
- **Legacy mode:** sites share every store but cookies.
- **Shared id:** a record that reuses an id binds the same container (R8).
- **Nested screens, popups and hosted tabs:** these run in the opener's container whatever page they show.

## 2. The lab

### Parties

| Party | Holds | May | May not |
|---|---|---|---|
| App under test | a fresh install per run of the build the integration tiers already use; its seeding hook (`WS_DIAG_SEED`, `ws_diag_seed`, debug builds only) lists the sites and does nothing else | run as built | be modified, instrumented in process, or given test-only bridges |
| Victim fixtures | victim sites on their own registrable domains (`victim-a.test`, `victim-b.test`), each with an account and fresh canaries | write their canaries through normal web APIs the first time they load: cookies (`HttpOnly`, `Secure` and plain), localStorage, IndexedDB, DOM text, a picked media file | be read by the attacker |
| Attacker | its own origins (`attacker.test`, `cdn-attacker.test`, a `*.googleapis.com`-shaped path where a scenario needs one), its HTML, JavaScript and server responses | edit its pages and server, trigger the interactions its scenario allows | read victim fixtures, drive the app's automation, read app or engine state, change the app, the tests or the evaluator |
| Collector | an evaluator-owned endpoint on `collector.test`, and the egress recorder every request from the app passes (the Linux tier's `egress_recorder.py` and `leak-origin`) | log every request and response | be written by anyone but the network |
| Evaluator | the canaries, the privileged automation (`integration_test` driver, `adb`, `dumpsys`, the OS permission state), the scenario scripts and the verdicts | drive user actions a scenario names, read OS evidence, score | grant any approval a scenario does not list |

**Network:** one resolver and one recorder, both evaluator-owned. Every name
resolves through them, and a lab CA serves TLS so pages run in a secure context.
The app trusts the CA as a user CA, which tls-trust-prompt allows.

### What the attacker sees

- **Its own pages:** what their JavaScript can observe there.
- **Its own server's logs.**
- **A bounded verdict per attempt:**
  - the scenario id;
  - the outcome class (section 3);
  - whether each reachability control fired;
  - a coarse error category.

The verdict carries no canary value, no victim state, no screenshot, no OS
evidence and no app log. Attempts are budgeted per scenario.

### User actions

A scenario names every user action it includes, for example:
- "taps the link";
- "allows the camera for `attacker.test`";
- "imports this file and confirms".

The evaluator performs exactly those and records them in the run transcript. A
prompt the scenario does not name is dismissed. An approval the attacker needs
but the scenario did not grant makes the attempt unsupported, not a pass.

## 3. Outcomes

Canaries are 128-bit random strings drawn per run per object. They are never
written to attacker-reachable inputs; a canary found in one is contamination,
and the run is invalid.

| Outcome | Requires |
|---|---|
| Confirmed violation | the collector or the recorder saw a canary of this run leave toward a non-victim origin, or independent OS evidence of a device or network action the policy denies:<br>- `dumpsys notification` lists a post under the victim site's name;<br>- `dumpsys media.camera` shows the camera open while only a foreign document asked;<br>- the emulator's location canary reaches the collector;<br>- a request from site A arrives at site B's proxy upstream. |
| Attempt completed, no violation observed | the reachability beacon (the attack page loaded, as the origin and surface intended) and the completion beacon both reached the collector, the run's positive control was detected, and no canary or forbidden action was seen |
| Unsupported or unexercised | the platform lacks the feature (no containers, no real screen share), the scenario's precondition did not occur, or it needed an approval the scenario does not grant |
| Invalid or inconclusive | a control failed, the recorder dropped data, the app crashed or hung, or a canary reached an attacker input |

**Controls in every run:**
- **Positive control:** a victim page that sends its own canary to the collector. It must be detected, or the run is invalid.
- **Vulnerable build:** a build with one planted policy mistake, for example the pre-#887 grant rule. It runs the same scenarios and must show the violation the clean build blocks, or the scenario is not measuring anything.
- **Absence is never evidence.** "No request seen" counts only when both beacons and the positive control fired. The attacker's own claims count for nothing.

**The adaptive loop:**
1. The attacker proposes a page and server behaviour.
2. The evaluator runs it on a fresh install.
3. The attacker gets the bounded verdict and revises.
4. A confirmed violation is minimized (fewer files, fewer steps) and kept as a regression fixture with its trace.

**Overfitting and reward hacking:** scoring uses held-out canary types (an IndexedDB canary, an `HttpOnly` cookie, an HTTP auth credential) and held-out scenarios. The attacker never sees them, so a strategy that only fits the shown cases scores nothing on these.

## 4. Scenarios, by priority

| # | Scenario | Rules | Starts from |
|---|---|---|---|
| S1 | A foreign document in a nested screen, a hosted tab and a popup tries the opener's grants: camera and microphone (a virtual source carrying a canary frame), live location (the emulator's canary fix), notifications, protected content | R2, R6 | fixed in #887 (PERM-001, SEC-043); the pre-fix build is S1's vulnerable control |
| S2 | A cross-origin iframe in a victim site calls every bridge handler directly: capture, location, notifications, downloads, media session, user-script handlers | R3, R4, R5 | CAM-014, LOC-011, NOTIF-010; downloads act on a global task id with no frame check |
| S3 | Two WebSpace sites on the same origin, then on the same registrable domain: each reads the other's canaries | R1, R8 | container mode must hold; legacy mode is expected to leak non-cookie storage, reported per platform as a confirmed violation of R1 |
| S4 | Navigation, popups and workers while an operation is pending: a prompt answered after the document navigated, a share across a reload, a worker and a service worker realm asking for the same capability | R2, R5, R6 | SEC-029, US-007; service workers get no shim |
| S5 | A crafted import, accepted through one modeled "import and confirm": a backup whose site reuses a victim's id, sets a proxy or broad domain claims; an archive section with `real` grants and enabled scripts | R7, R8, R9, R10 | SEC-041 (open), SEC-044 (reported), BACKUP-015 |
| S6 | CAPTCHA classification: a page under `storage.googleapis.com/<bucket>/recaptcha/` opens a Verification popup without a gesture, then navigates its opener | R10 | SEC-042 (open) |

### Platform coverage

| Tier | Engine | Bridge | Counts as |
|---|---|---|---|
| Browser (`test/browser`, Puppeteer) | Chromium | a mock `callHandler` | a baseline for page-side shims only; **never evidence about the native bridge** |
| Linux WPE (`build-linux` job) | WPE WebKit, containers | real | native result, Linux |
| Android emulator (`build-android`, API 35) | System WebView, `MULTI_PROFILE` | real | native result, Android; `dumpsys` evidence |
| macOS (`build-apple`) | WKWebView | real | native result, macOS |
| iOS simulator | WKWebView | real | screenshot jobs only today; later |

Each verdict names its tier. A result from a mocked bridge is never reported as
the app's native behaviour.

## 5. Plan

| Stage | Delivers | Accepted when |
|---|---|---|
| 0. Policy as data | the matrix above as `docs/security/policy.md`, each rule naming its owner and its check, or "unverified" | every R-rule has an owner; spec ids resolve |
| 1. Evaluator on Linux WPE | canary generator, victim fixture server, collector, recorder wiring, seeding by `WS_DIAG_SEED`, verdict classifier, positive control | the positive control is detected in 20 of 20 runs; a clean run classifies as completed with no violation |
| 2. S1 and S2 on Linux | the scenarios as scripts; the pre-#887 build as S1's vulnerable control | the vulnerable build shows S1's violation and the clean build does not, in 10 runs each |
| 3. Android tier | the same harness under the emulator, with `dumpsys` and location evidence | S1 and S2 classify on Android as on Linux |
| 4. S3 and S5 | same-origin sites in both isolation modes; the import scenarios with one modeled consent | legacy-mode leaks are reported, not hidden; SEC-041 and SEC-044 reproduce on the vulnerable build |
| 5. The adaptive loop | the attacker sandbox (write access to its pages and server only), the verdict API, minimization, the regression archive, held-out sets | a seeded agent finds S1 on the vulnerable build within budget, and its minimized fixture replays |
| 6. S4, S6 and macOS | the remaining scenarios and tier | each scenario has a vulnerable control that fires |

## 6. Remediation queue

| Finding | Rule and owner | Smallest fix | Regression, and what must keep working |
|---|---|---|---|
| Grants follow the surface, not the origin (SEC-043) | R2, `GrantStore` | done, #887 | PERM-001 tests and gates; the site's own pages keep their grants, its embedded frames CAM-014 |
| Archive sections keep `real` grants and enabled scripts (SEC-041) | R7, the archive restore | run `sanitizeImportedSites` on sections restored from a backup | a restored section opens with `ask` and disabled scripts; a local close and reopen keeps local consent |
| Archive identity collisions (SEC-044) | R8, archive open | re-mint an archived id that an app-tier or other open archive site holds, before materialising; key containers by tier | an archive site sharing an app-tier id gets its own container, and its close erases nothing of the app-tier site |
| Captcha classification by path (SEC-042) | R10, `isCaptchaChallenge` | match `/recaptcha/` only on the reCAPTCHA hosts, and require a gesture for a Verification popup | a bucket path opens a plain popup; a real reCAPTCHA challenge still opens in place |
| Download handlers take a global task id with no frame or view check | R4, `DownloadsService` | bind a task to the `ViewKey` that started it | a frame cannot fail or complete another view's download; a page's own blob download still saves |
| The notification polyfill's config carries the raw site id into every frame | R4, `page_scripts.dart` | drop the id from the page config; Dart uses its own | posts still name the site |
| A foreign page reads `Notification.permission` as `granted` | R2, the polyfill | ask the frame-aware handler at load | the site's own pages still read `granted` |

Each finding the lab confirms gets an entry in the review file it belongs to,
with its trace, its fix and its regression test, as the README describes.

## 7. Assumptions and limits

- **Trusted, not tested here:**
  - the engines, the OS, the keystore and the plugin fork;
  - the bridge preamble's `origin` and `isMainFrame`, which S2 probes from outside but cannot prove.
- **No renderer compromise or memory corruption:** an attacker who escapes the engine's sandbox defeats R1 to R6. That needs other methods.
- **The emulator is not a device:** camera, location and notification evidence there is the emulator's.
- **The legacy isolation mode does not meet R1** for non-cookie storage. The lab reports it; it cannot fix it.
- **Coverage is bounded by the attempts made:** a budgeted agent and six scenarios are a sample, and held-out sets only show whether the sample generalised.

## TL;DR

- **The policy:**
  - subjects (site, surface, origin, frame, document, standing) and objects;
  - ten default-deny rules, each with the component that enforces it;
  - OS access control separates the app from other apps, never one site from another, and at-rest encryption is not access control.
- **The lab:**
  - parties: a disposable app, victim fixtures with per-run canaries, an attacker limited to its own origins, an evaluator-owned collector and recorder;
  - verdicts: four outcome classes, with positive and vulnerable-build controls in every run.
- **Order:** S1 first. Its pre-#887 build is the first vulnerable control. Then the frame bridge, same-origin sites, imports (SEC-041, SEC-044), and captcha (SEC-042).
- **Missing from this repository:** the 2026-11-02 review. Its SEC-044 is referenced by id only.
