# CLAUDE.md

WebSpace: Flutter app managing multiple websites with per-site cookie isolation via flutter_inappwebview. Platforms: iOS, Android, macOS, Linux (WPE WebKit fork).

## Coding principles

Simplicity comes first: every structure here exists to make the code easier to hold in the head; one that makes it harder has failed, however correct it is. Within that: one owner per fact, joins are types, and every invariant is caught at the earliest point it can be violated. A bug then has one suspect.

### The ladder

Each invariant sits on one rung. Put it on the highest rung Dart allows; step down only with a one-line reason next to the check.

| Rung | Caught by | Dart form |
|---|---|---|
| 0 | decided before run time | `const` data; `extension type` ids; enum with fields; one field registry every serializer iterates |
| 1 | the compiler | `sealed` + exhaustive `switch`, no `default` or `_`; records with `required` fields; a scope object that does in the constructor and undoes in `dispose` |
| 2 | an assert at the owner | `assert(cond, 'why')` on entry to the compartment that owns the fact |
| 3 | a self-check | the owner recomputes its result independently and compares |
| 4 | a boundary test | the compartment driven through its public type with a fake that models the other side |
| 5 | a gate | a test over source text; its header says what a type could not express |
| 6 | prose | a paragraph here or a doc comment; catches nothing |

An invariant written as a comment is on rung 6. `tab_lifecycle_engine.dart` says in a `///` that a tree has "an `activeTabId` that names a member"; as `assert(tabs.any((t) => t.id == activeTabId), 'activeTabId names a member')` the comment goes. A swallowed error (`catch (_)`) is below rung 6.

**Check**: break the invariant on purpose. If a reviewer or a grep is what catches it, it is on the wrong rung.

### Rules

1. **One owner.** A fact is computed in one place; everything else reads it. Two places agreeing today is still a bug. The UI never restates a rule. A decision has one owner too: a job this codebase already does (a guard, a dialog, a store, a "follow app" choice, a sync primitive) is done the way the map or the existing code does it. A second way needs one line saying why, and then replaces the first everywhere in the same change, or is listed as debt. *Check*: a bug fix that edits two compartments means the fact had two owners; a new idiom beside an old one for the same job is a fork; fix the ownership.
2. **Small typed joins.** Between compartments passes a record, class or sealed type, never a parameter list, map or string. More than four parameters is a missing type. A reader needs about four entities to follow a change; more means a join is misplaced. An abstraction earns its place by removing a copy, a forgotten-item failure or a parameter list; one that only adds a hop (a single caller, a generic parameter nobody varies, a wrapper that renames) is inlined. Every hop is a join that has to be proven valid too (a type, an assert, a boundary test), so an unneeded one is paid for twice: once in reading, once in validation. *Check*: did a join in the map change shape? One line why.
3. **Fixed cost per axis.** Adding one item (a per-site field, a pref, a capture kind, a settings row) touches a fixed set of places through one funnel, and forgetting it anywhere fails to compile. *Check*: edit sites against the budget table; over budget, build the funnel first in its own commit.
4. **Layers point down.** UI → model → services → values → platform (the map lists the directories). A file imports its own layer or lower. Engines (`*_engine.dart`) decide and are pure: no Flutter import, no I/O, no `context`; tests import them with fakes that model the interface. *Check*: [`test/js/layers.test.js`](test/js/layers.test.js) (rung 5: Dart has no module boundary a type can enforce); its debt list only shrinks.
5. **Ids are types.** `extension type SiteId(String raw) {}`; a `String siteId` parameter is a square where a move was meant (`Host` in `services/url_host.dart` is the model). Constant data is `const`; a field is declared once and every serializer iterates the declaration. *Check*: any new `String` id, startup-built table, or hand-written per-field line?

### Fixing a bug

Name the fact and its owner. No single owner: that is the bug; pick one and delete the copy. Owner exists: fix it there, never a reader. Then lift the invariant one rung so this class cannot recur. Recurring: append to `docs/bugs/`.

### Before finishing

- Each new type explains itself in one sentence and removes more than it adds for a reader.
- One compartment touched, or one line why not.
- No join changed shape, or one line why.
- A forgotten item would fail to compile.
- Imports point down; new logic is a pure engine with a boundary test.
- Nothing new on rung 5 or 6 without the line that names what would lift it.

### This section

Rules are fixed; a new one replaces one. The map grows one row per item. No recipes: a numbered list of edit sites is an axis without a funnel and belongs in the budget table as debt (the recipes further down this file are listed there). No restating a spec, type or test; link it. Area detail goes in `lib/<area>/CLAUDE.md`. When a gate becomes a type, delete the gate and its paragraph in the same commit.

### Map

| Compartment | Owns | Join |
|---|---|---|
| `SitePosture` (`services/site_posture.dart`) | a site's resolved settings in six groups, resolved once by `WebViewModel.sitePosture` | `LaunchUrlFunc(url, posture, {homeTitle})`; `WebViewConfig.posture` |
| `site_overrides.dart` | archive-tier and Tracking Protection overrides | `TrackingProtectionForce`, `ArchiveFold`; read through `effective*` getters and by screens |
| `WebViewHostHooks` | the host's answers to every site webview: prompts, outbound links, capture | one required-field class, passed whole |
| `BlockDecision` | whether a request is blocked, and by which blocker | `decide(BlockQuery)` → sealed `BlockVerdict` |
| `pageShim` (`services/page_shim.dart`) | how a page shim is injected | `pageShim(group, js, frames:)`; `ShimFrames` has no default |
| `site_unload_engine.dart` | which steps an unload runs | `enum UnloadReason` |
| `OrphanSweepEngine` | the one orphan sweep and its store list | `enum OrphanStore` |
| `CaptureKind` / `GrantStore` (`settings/capture.dart`, `services/media_grant_engine.dart`) | capture kinds and their grants | enum over three mode enums, `grantOf`/`withGrant` switches; sealed `GrantStore` |
| `AppPref` (`settings/app_prefs.dart`) | every global pref, its default, what a backup carries | `AppPref.x.value` / `.set(v)`; backups iterate `AppPref.values` |
| `SecureJsonStore` / `Keystores` / `KeychainAead` | secrets at rest and their keychain options | `SecureJsonStore<T>` on a `Keystores` set |
| `host_platform` (`platform/`) | dart:io primitives, importable from plain Dart | conditional export |
| `ReentryGuard` | one run of an async UI handler at a time | `guard.run(() async {...})` |
| `Guarded<T>` / `SiteEventInbox` (Kotlin) | native state shared with IO threads | reachable only inside `with { }` |

Layers: UI `screens`, `widgets`, `controllers`, `main.dart` · model `web_view_model.dart`, `demo_data.dart`, `diag_seed.dart` · services `services` · values `settings`, `utils`, `webspace_model.dart` · platform `platform`.

Debt, files importing upward (the gate's list, target 0): services → model (engines take `WebViewModel`; each needs a narrow interface) · services → UI (`webview.dart` → `root_messenger`, `surface_nudge_scope`).

| Axis | Budget | Now | Funnel |
|---|---|---|---|
| per-site field | 3 | ~7 edits, 4 files | `SitePosture` group; debt: a field registry for the model's constructor, `toJson`, `fromJson` |
| pref | 2 | 2 | `AppPref` |
| capture kind | ~5 files | ~5 files | `CaptureKind` |
| settings row | 1–3 lines | 1–3 | `SettingTile` / `ChoiceTile` |
| secret store | 2 | 6 ("Adding a new credential / secret" below) | `SecureJsonStore` + `OrphanStore`; debt: hydration, post-import notice, export test by hand |

Flag for review before changing: persisted formats, the Dart to page-script bridge, any join above.

Health, monthly: `node tool/architecture_health.js` prints files per fix commit, gates, `catch (_)`, asserts per 1k lines, comment share, `String` ids, hand-kept `toJson`/`fromJson` classes and layer violations, each with the direction it should move.

## Style (output, code, commits)

- No preamble, no closing fluff, no em-dashes, no emoji.
- **End a long answer with a TL;DR.** Long is roughly more than a screen, or
  more than two sections. It is the one closing section that is not fluff, so
  it carries facts a reader can act on (what changed, what it means, what is
  still open), never a recap of the headings above it. Short answers get none.
- Don't use the phrase "load-bearing".
- Code first; explain only the non-obvious.
- Default to **no code comments**. Only add when the *why* is non-obvious (hidden constraint, workaround for a specific bug, surprising behavior). Never restate what the code does. Never reference the current task or PR.
- Commit messages: short subject (<70 chars, imperative), 1-2 line body for the *why* if needed. No marketing prose, no bullet lists of every changed file, no "this commit also...".
- Don't speculate. Read the code or docs before asserting an API/version/flag.
- **No catch-alls.** Catch the types the call is known to throw (`on SocketException`,
  `test: (e) => e is SocksClientException`), never `catch (_)`, `on Object` or
  `onError: (_) {}`: those also swallow `Error`s, which are bugs, and leave nothing
  to fail the test that would have caught them. When a failure already has an
  owner (a future dart:io observes, a request that reports it), don't add a
  second listener to silence it; restructure so there is one. The existing
  `catch (_)` sites predate this rule; don't copy them.

## Subagents

- Never spawn a subagent on a Fable model (`model: "fable"`, or a workflow
  `agent()` call that picks one) unless the user has explicitly allowed it in
  the current conversation. Omit `model` or pick another one instead.

## Shipping macOS

macOS is a release target, not just a dev platform: signing happens after the
build (`scripts/sign_macos.sh`), the entitlements name team-prefixed groups
that an ad-hoc signature cannot back, and a capability entitlement has to
agree with its `ENABLE_*` build setting. Read
[docs/releasing-macos.md](docs/releasing-macos.md) before touching
`macos/Runner/Info.plist`, either entitlements file, or the signing settings
in the Xcode project. Spec: PLATFORM-006.

## Git

- Never push to master. Branch first.
- `git pull --rebase` always.
- **A PR branch takes master by rebase, never by merge.** By default a PR lands
  as: `git rebase origin/master`, push with `--force-with-lease`, squash-merge.
  Never `git merge master` into the branch, not even to resolve a conflict. A
  merge commit buries the PR's diff under master's and hands the squash a
  history nobody reviewed. Resolve conflicts commit by commit so the
  translation split below survives the replay.
- Before pushing a branch, check it still exists on remote; if merged+deleted, branch fresh from master.
- **Translations ride their own commit.** A change that adds or renames a user-facing
  string commits the code plus `lib/l10n/app_en.arb`; the other 66 `app_*.arb` files
  go in a second commit on top of it. A 67-file translation diff otherwise buries the
  change a reviewer actually needs to read. Applies equally to a key rename (the
  settings-hints subtitle/hint move) and to adding a locale.
  Ordering matters: the code commit on its own fails `l10n_coverage` (it enforces key
  parity across every locale), so put the translation commit immediately after and push
  them together. CI runs the pushed head, not each commit, so the pair is green even
  though the first half is not; a bisect that lands between them will fail l10n, which
  is the accepted cost of the split.
- **A replay never changes who wrote a commit.** `git rebase` and `git cherry-pick -x` keep the author; nothing that replays commits may rewrite it. No `--reset-author`, no `git commit -s`, no `git rebase --signoff`, and no re-picking without `-x`. A commit carries at most one `Co-Authored-By:` per identity and no `Signed-off-by:` at all, so replaying a branch cannot grow its trailer block. Taking someone else's commit (a fork, another branch): keep their `--author`, write your own message for what the change does *here*, and cite the origin with one `Cherry-picked-from: <sha> (<repo>)`. Gate: [`scripts/check_commit_attribution.sh`](scripts/check_commit_attribution.sh), run in CI's `validate` job.
- After a rebase across a commit that touched `lib/l10n/*.arb`, run `fvm flutter gen-l10n` before trusting the test run: `lib/l10n/gen/` is gitignored, so a stale copy fails to compile against the new keys and the failures look like the rebase broke something.

- **`[ci-only: <jobs>]` narrows a CI run.** A commit message carrying it runs only
  the jobs it names and skips the rest; tokens are `validate`, `design`, `android`,
  `linux`, `apple`, comma-separated (`[ci-only: apple,validate]`). For a bisection
  that reads one tier this is the difference between one runner and five. It is
  honoured on `pull_request` only, so a marker that survives a merge cannot silence
  master, and the guardrails are gated by
  [`test/js/workflow_shell_syntax.test.js`](test/js/workflow_shell_syntax.test.js).
  Don't use it on a commit whose change could break another platform.
- **Don't commit derivatives.** If a file is the output of a script, parser, compiler, dumper, or any build step that reads from elsewhere — it doesn't belong in the repo. Commit the inputs (sources you author, pinned upstream refs) and the *runner* (build.rs, scripts, Cargo features); regenerate the output at build time into `$OUT_DIR`/`build/`/`target/`. Same applies to vendored third-party source: if a script can fetch + assemble it from upstream at a pinned ref, don't check the upstream tree in. Concrete check before staging: "could I delete this file and reproduce it by running one command from a clean clone?" — if yes, it's a derivative; ignore it. See `rust/webspace_adblock/build.rs` for an example.
  One exception: `test/fixtures/backup_compat/<tag>/` is what a shipped release exported. A
  release's output never changes, and rebuilding it means checking out and `pub get`-ing
  every old tag, so the corpus is committed; `tool/backup_compat/generate.sh` is its runner.

## Sandbox bootstrap

Fresh sandboxes lack `fvm` and may lack `nvm`/Node. Skip a block if `command -v fvm` (or `node`) already prints a path — don't reinstall.

```bash
# fvm — required (.fvmrc pins Flutter 3.38.6)
curl -fsSL https://fvm.app/install.sh | bash
export PATH="$HOME/fvm/bin:$PATH"
fvm install

# nvm + Node — only if a script under scripts/ or tool/ needs Node
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts

# Swift — only to run tool/swift_typecheck/check.sh, which type-checks the
# Apple plugin sources no other tier compiles. It exits 0 with "no swiftc on PATH,
# skipping" when Swift is absent, so without this the gate is silently not a
# gate, which is how `proxyConfigurations?.count` reached CI once.
curl -fsSLO https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init --quiet-shell-followup --assume-yes
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
```

## Commands

Prefix all Flutter/Dart with `fvm`.

```bash
fvm flutter pub get
fvm flutter test                                         # all Dart tests
fvm flutter test test/cookie_isolation_test.dart         # single file
npm run test:js                                          # JS shim tests (jsdom)
./scripts/test_all.sh                                    # Dart + JS
fvm flutter analyze
fvm flutter build apk    --flavor fdroid --release       # F-Droid (CI, unsigned)
fvm flutter build apk    --flavor fmain  --release --split-per-abi   # Play (signed)
fvm flutter build ipa    --release                       # iOS unsigned
fvm flutter build macos  --release                       # unsigned; see below
./scripts/sign_macos.sh devid                            # notarized zip (needs certs)
./scripts/sign_macos.sh mas                              # Mac App Store .pkg
fvm flutter build linux  --release
fvm dart run flutter_launcher_icons
```

Android flavors: `fdroid` (CI), `fmain` (Play), `fdebug`. The `debug` build type
suffixes the applicationId (`org.codeberg.theoden8.webspace.debug`, label "Webspace
Debug") so a dev build installs beside a store one; the namespace is unchanged, so
`adb` component names in `scripts/` must be fully qualified, not `pkg/.Class`.

## Architecture

**Models**
- `WebViewModel` ([lib/web_view_model.dart](lib/web_view_model.dart)) — site with URL, cookies, per-site settings (language, incognito, proxy, etc.). Unique `siteId` keys cookie isolation.
- `Webspace` ([lib/webspace_model.dart](lib/webspace_model.dart)) — named collection of site indices. `__all_webspace__` shows all.

**Main** — [lib/main.dart](lib/main.dart): `WebSpaceApp` (root MaterialApp) and `WebSpacePage`, whose state holds one `SiteRuntime` `_sites` ([site_runtime.dart](lib/controllers/site_runtime.dart): the models, loaded positions, current site, webspaces) and the controllers in [lib/controllers/](lib/controllers/) (shortcuts, archives, surface repaint, background sites, app lifecycle, site network, tabs, links). A controller talks back through its typed `*Host` interface, implemented by `_PageHost` at the bottom of main.dart; `lib/services` never imports a controller.

**Site-set changes** — every add, delete, move, edit, import, archive open/close goes through `_commitSites(SiteSetChange)` ([site_set_change.dart](lib/controllers/site_set_change.dart)). The sealed change's `effects` record (every field required) decides what follows it, and the funnel runs those steps in one fixed order, so a new kind of change does not compile until it answers each one.

**Services** ([lib/services/](lib/services/)) — `cookie_secure_storage`, `html_cache_service` (AES, clears on upgrade), `icon_service`, `dns_block_service`, `webview` (CookieManager wrapper, WebViewTheme).

**Cookie isolation — two engines, runtime-selected.** `SiteRuntime.useContainers` caches `await ContainerNative.instance.isSupported()` at startup and gates the path.

- **Container engine** ([container_isolation_engine.dart](lib/services/container_isolation_engine.dart)) — Android System WebView reporting `MULTI_PROFILE` (runtime-detected, no published milestone version), iOS 17+, macOS 14+, Linux WPE WebKit 2.40+. Each `siteId` → native container `ws-<siteId>` (`androidx.webkit.Profile` / `WKWebsiteDataStore(forIdentifier:)` / `WebKitNetworkSession` cached under `<XDG_DATA_HOME>/flutter_inappwebview/containers/`) owning its cookies, localStorage, IDB, ServiceWorkers, HTTP cache. Same-base-domain sites load concurrently — no conflict-unload, no capture-nuke-restore. Bridge: [`ContainerNative`](lib/services/container_native.dart). Lifecycle ops route through fork's `inapp.ContainerController`; only the Android `MULTI_PROFILE` feature gate lives in [`WebSpaceContainerPlugin.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebSpaceContainerPlugin.kt). Bind happens in `InAppWebView.prepare()` / `preWKWebViewConfiguration` / Linux `webkit_web_view_set_property("network-session", ...)`, driven by stock `inapp.InAppWebViewSettings.containerId` set by `WebViewFactory.createWebView`. Spec: [openspec/specs/per-site-containers/spec.md](openspec/specs/per-site-containers/spec.md).
- **Legacy engine** ([cookie_isolation.dart](lib/services/cookie_isolation.dart)) — Windows, web, anywhere `ContainerController.isClassSupported` is false. Sites with matching base domains can't load simultaneously; switching unloads the conflict and runs capture-nuke-restore on the shared cookie jar. Spec: [openspec/specs/per-site-cookie-isolation/spec.md](openspec/specs/per-site-cookie-isolation/spec.md).

**Other patterns** — Lazy webview loading (`SiteRuntime.loaded`); `isDemoMode` flag (no persistence, seeded data).

**flutter_inappwebview fork** — adds containers + per-site iOS/macOS proxy. Monorepo: <https://github.com/theoden8/flutter_inappwebview>. `dependency_overrides` in [pubspec.yaml](pubspec.yaml) pin every platform plugin to one git ref. Pub caches under `~/.pub-cache/git/`. Currently a mutable branch — tag it before each release. Surface area: `grep -rn '\[WebSpace fork patch\]' ~/.pub-cache/git/flutter_inappwebview-*/`.

**Persistence** — SharedPreferences for sites/webspaces/theme; cookies in flutter_secure_storage by `siteId`.

## Tests

Dart in `test/`, integration in `integration_test/` (screenshots).

## Design (`tool/design_gallery/`)

`web/` exists only so a designer can drive the real UI in a browser and so it
can be screenshotted for review; the app is not shipped for web and the WebView
does not run there. Two targets, both via `scripts/design_web.sh`:
`app` ([lib/design_app/main.dart](lib/design_app/main.dart), the real
`WebSpaceApp` on demo data) into `build/web`, and `gallery`
([lib/design_gallery/main.dart](lib/design_gallery/main.dart), one card per
widget) into `build/design_gallery`. `npm run design:serve` serves either.
The Claude Design project cannot build Flutter, so it asks for a rebuild
through the dated `_requests/refresh.md` mailbox (design-side state, gitignored
here). Design artifacts that come out of that pipeline live in `assets/design/`
under the `assets/` artwork licence, which names the designer; artwork by
anyone else is case by case and gets its own licence file. Full workflow and constraints
(canvas output, local fonts, web-clean check, refresh protocol):
[tool/design_gallery/CLAUDE.md](tool/design_gallery/CLAUDE.md). Spec:
[openspec/specs/design-gallery/spec.md](openspec/specs/design-gallery/spec.md);
DESIGN-001 (every UI file compiles for web) is enforced by `npm run design:check`
in CI's `validate` job, and the two web builds by the `design-web` job.

## Recurring bugs (`docs/bugs/`)

A **recurring bug** is one whose symptom was fixed before and resurfaced through a
new code path (the fix was partial). When you hit one, do NOT just patch the new path
silently — record it so the next person sees the whole lineage and the still-open gaps.

- One file per bug, numbered: `docs/bugs/NNN-<slug>.md` (e.g. `001-white-screen.md`).
  Number bugs sequentially; the number is the bug's stable ID (`BUG-NNN`), used in the
  file header. Reuse the existing file when the same bug recurs — never start a new one.
- Each file has: the **symptom**, the **root mechanism / invariant** (why all instances
  share a cause), a numbered **chronological list of fix attempts**, and a **known open
  gaps** section.
- Every fix attempt entry MUST carry: a number, the **date** (`git show -s --date=short`),
  the PR/commit, **what it did**, **why** (the reasoning), and **why it was partial**
  (which path it covered and which it missed). Append a new entry per attempt; never
  rewrite history.
- This file is the bug's biography; the **spec** (`openspec/specs/.../spec.md`) still
  carries the normative requirement + regression scenario for each fix. Cross-link them.
- When a bug is genuinely closed for the whole class (not just one path), set the header
  `Status:` to `closed` and say what finally subsumed the per-path fixes.

GitHub issues/PRs track "what broke"; `docs/bugs/` tracks "every attempt and why each
was incomplete"; OpenSpec tracks "the behavior we now require". Keep all three in sync.

## Security reviews (`docs/security/`)

Whole-app security reviews are expensive to run, so every run is persisted as
`docs/security/NNNN-MM-DD-review.md` with stable `SEC-NNN` ids, a status column, and a
**Verified safe** list of paths already checked. Before touching a bridge, shim, proxy
path, import path or the archive, read the latest run's findings for that area; before
starting a new review, read [docs/security/README.md](docs/security/README.md) for the
method, the threat model, and the four recurring shapes to grep for first. Close a
finding by editing its status row (cite the commit), never by deleting it; a finding that
resurfaces through a new path becomes a `docs/bugs/` entry linked from the run file.

## Formal verification (`formal/`)

Defense-in-depth pipeline; each layer absorbs a class of issue before the next:
`spec → formal → engine → tests → app code → integration tests`. The **formal** layer
([formal/](formal/), TLA+ checked by TLC) catches what tests can't: design contradictions,
missing-transition classes, and cross-spec interference — bugs in the gaps *between* specs.

- `formal/kernel.tla` is the **cross-spec kernel**: only the specs that mutate *shared*
  runtime/persisted state get a module (owned vars, actions, invariant, rely/guarantee
  contract). Independent (leaf) specs share no state and compose for free — keep them OUT.
- Cite requirement IDs (`PAUSE-018`, `ARCH-001`, …) on the actions/properties that encode
  them so spec ↔ model stays grep-able.
- **Adding a spec that touches shared state → run the mix gate:** add its actions to `Next`
  and its property to the `.cfg`, then `./formal/check.sh`. A counterexample means it does
  not mix; the trace names the breaking interleaving. Fix the design, not the model.
- Standalone models (no shared kernel state) live beside the kernel: `archive.tla`
  (ARCH-001 byte-identity, a 2-safety hyperproperty via self-composition), `renderer.tla`
  (BUG-002 dead-renderer recovery), `proxy.tla` (mismatched-proxy mutual exclusion),
  `kiosk.tla` (KIOSK-001/002/003 locked-shell sealing).
- Each model carries **negative** demonstrators (a mutation that MUST be caught) and
  **positive** reachability witnesses (a legal behavior that MUST be reachable) — run by
  `./formal/check.sh`. `trace/` validates real `LogService` traces against the kernel's
  observable projection (the model↔code bridge).
- `formal/proofs/` holds **unbounded TLAPS proofs** (machine-checked by `tlapm`): every
  kernel safety invariant *and* the surface-repaint liveness `RepaintLiveness` for all N,
  not just TLC's N = 3. Run via `proofs/check_proofs.sh` (in the `validate` CI job).
- A bug's recurrence is also gated in **code**: structural Node tests under `test/js/`
  (`surface_repaint_funnel`, `renderer_gone_recovery`) fail CI if a new path skips the fix.
- Don't commit `tla2tools.jar`, `states/`, `.tlacache/`, or generated `mc_*.tla` (derivatives).
- Full method + the new-spec workflow: [formal/README.md](formal/README.md).

## OpenSpec features

Specs live under `openspec/specs/<slug>/spec.md` (Given/When/Then). **Read the relevant spec before modifying a feature.** A slug marked *(change)* is implemented but not archived yet, so its requirements are still at `openspec/changes/<slug>/specs/<slug>/spec.md`. Slugs:

| Slug | One-liner (when not obvious) |
|------|------|
| accessibility | which of Apple's nine accessibility labels the app may claim per device (all No today, with what blocks each); Android's bar instead (core app quality touch targets, contrast, descriptions; the Play pre-launch report every release); which OS settings reach the chrome and web content on every platform; shims pass the engine's own accessibility media features through |
| always-open-home | per-site: navigation URL reverts to `initUrl` on cold start and shortcut tap, cookies and other stored state survive; site switches and a transient background are not resets |
| captcha-support | |
| clearurls | tracking-param removal, per-site toggle |
| legal | App Store encryption declaration + licence composition of the shipped work |
| configurable-suggested-sites | empty default for fdroid |
| content-blocker | ABP filter lists via adblock-rust (network, cosmetic, procedural, $redirect/$csp/$removeparam); per-site list selection is a mask over the app-wide set |
| cookie-secure-storage | encrypted cookie persistence |
| design-gallery | designer works in Dart on web; web-clean, token-validity, render-matrix and card gates |
| desktop-mode | per-site UA → JS shim (userAgentData, maxTouchPoints, viewport rewrite) |
| developer-tools | JS console, cookie inspector, HTML export, app logs; in developer mode a background log that outlives the process (native refresh steps, wakes, unloaded notification sites, OS gates) with site names kept in memory only |
| dns-blocklist | Hagezi list, severity levels, per-site toggle; per-site level is a mask over the app level (the levels do not nest, so each domain carries a bit per level) |
| downloads | http/https/data/blob, streamed progress + save dialog |
| external-scheme-handling | intent:// auto-resolves to http(s) fallback (silent route); prompt only when no web equivalent |
| file-import-sites | local HTML via HtmlCacheService |
| fullscreen-mode | hide app bar/tab strip/system UI; per-site auto |
| home-shortcut | Android pinned shortcuts; iOS/macOS expose an "Open Site" App Intent through Shortcuts instead (no pin API) |
| http-auth-prompt *(change)* | |
| https-upgrade *(change)* | plain-http main-frame navigations retried over https, silent per-host fallback; default-on knob, forced on by Tracking Protection |
| icon-fetching | progressive favicon w/ fallbacks; the page's own icon wins when it is on the site's host, >= 32px, and not a badge swapped in after load: on Android the one the webview reports (`onReceivedIcon`); elsewhere the links the page declared, fetched through the site's proxy and blockers. The Site icons only experiment drops Google/DuckDuckGo and sends Android to the declared links too; developer mode can reset every icon cache |
| incognito-mode | per-site: nothing the site stores survives an app restart (cookies, localStorage, IDB, SW, cache, last URL/title); typed configuration does |
| ios-universal-link-bypass | cancel+reissue gesture http(s) navs to dodge AASA |
| ip-leakage | proxy coverage contract; fail-closed on SOCKS5; WebRTC + DNS |
| js-shim-tests | jsdom + node:test, with Dart drift check |
| kiosk-mode | per-site toggle; shortcut launch opens chrome-less (no drawer/tab strip/menus/settings), plain app launch restores access; no passphrase |
| language | Accept-Language + DOCUMENT_START navigator.language/Intl |
| localization | UI strings via gen_l10n ARB; no-unkeyed-text guard; coverage parity tests |
| integration-tests | flutter `integration_test/` harness conventions + headless Linux CI setup |
| lazy-webview-loading | on-demand creation, IndexedStack placeholders |
| localcdn | cache CDN resources locally (Android) |
| navigation | back gesture, drawer swipe, refresh, race guards; URL-bar site info sheet (site + container) |
| nested-url-blocking | nested InAppBrowser; gesture-less cross-domain hops blocked on every site (no switch); per-site external link mode (in app / browser / block), routing to other sites only in app |
| page-zoom | per-site zoom; viewport meta on mobile (Android pins the layout width), CSS `zoom` on desktop |
| passkey-support | every site outside an archive. Android: the shim hands `publicKey` requests to Dart, which asserts the calling frame's origin to Credential Manager (`CREDENTIAL_MANAGER_SET_ORIGIN`, a normal permission) with its own clientDataJSON hash; each provider decides whether to trust the app with an origin. Emulator gate: `scripts/run_android_passkey_tests.sh`. iOS/macOS: no bridge, WebKit's own WebAuthn, which needs Apple's browser passkey entitlement; an archive-tier site gets a block shim that hides it |
| per-site-cookie-isolation | legacy engine (fallback) |
| per-site-containers | native containers (preferred when supported) |
| per-site-location | geo + IANA tz override + WebRTC lockdown |
| platform-support | platform abstraction layer |
| proxy | per-site HTTP/HTTPS/SOCKS5; a proxy library (saved proxies, gateways, credentials tied to gateways) any site or the app-wide proxy picks from, with a connection indicator *(saved-proxies change)*; Android serialises mismatched-proxy sites |
| proxy-password-secure-storage | secrets in flutter_secure_storage; never in JSON |
| screenshots | integration-test driven |
| screenshot-block *(change)* | app-wide or per-site `FLAG_SECURE` (per-site applies while that site is on screen); Android only, switches absent where no public API blocks capture |
| app-settings *(change)* | App Settings as an index: Appearance, Behaviour, Network, Privacy, User scripts, Backup and archives, Developer; each row a screen of its own with a summary of its state (BEHAV-002 rule); one tap, one action on every opener |
| settings-backup | JSON import/export; every released format still imports (per-release fixture corpus), and an import is planned whole before it is applied |
| settings-hints | where a settings row's text goes: state in the subtitle, explanation behind the hint button; fixed-string subtitles capped across all locales |
| site-behaviour | per-site Behaviour screen: how the app hosts the site (opening + display, link handling), reached from one row under "Site" |
| site-network *(change)* | per-site Network screen: proxy, Tor exit, WebRTC policy, saved sign-ins, reached from one row under "Site" that names the route the traffic takes |
| site-editing | URL + custom name |
| site-permission-badges | drawer badges for location/camera/mic/background-audio grants; real device access vs simulated |
| site-settings-qr | share a site's configuration as a QR / `webspace://qr/site/v1/` URL; never carries secrets, cookies, user scripts or imported HTML |
| tls-trust-prompt | system + user CA trust by default; prompt only when the OS rejects a cert, then pin (host, port, sha256) so Dart-side clients match the webview |
| tor-proxy *(change)* | embedded Tor on iOS + macOS (the macOS Runner compiles `ios/Runner/TorControllerPlugin.swift`), per-site SOCKS5 circuit isolation (never per destination), no developer-mode or experimental gate. The macOS build is the only tier that runs the real handshake, and its Tor pod is why the macOS floor is 11.0. The Tor (external) experiment points Android (Orbot, InviZible), Linux and macOS (tor, Arti) at a tor already running, with the same per-site SOCKS credentials; on macOS it stands in for the built-in tor while on, switched without a relaunch (TOR-025) |
| tracking-protection | umbrella per-site ETP: forces ClearURLs/DNS/content blocker/LocalCDN + injects anti-fingerprinting shim (Canvas/WebGL/audio/fonts/screen/hardware/timing/clientrects) seeded by siteId |
| user-agent-identity | engine-consistent navigator identity for the per-site UA (vendor/productSub/oscpu/buildID/platform/userAgentData); complements desktop-mode |
| upstream-webview-defects *(change)* | defects found auditing the pinned flutter_inappwebview fork's upstream tracker: a declined `onCreateWindow` still navigating on iOS/macOS, UA client hints that half-spoof, the plugin's unmasked console wrappers, the real Linux WPE build floor |
| user-scripts | per-site JS injection w/ timing control |
| web-camera-access | per-site camera for camera-only getUserMedia (banking QR flows); `cameraMode` ask/real/virtual/block. Virtual serves a user-picked image/looped video via a canvas `captureStream` shim (no real camera, no OS prompt); real grant ensures Android CAMERA perm |
| web-microphone-access *(change)* | per-site audio capture; `microphoneMode` ask/real/virtual/block. Real hands over the device mic under the MIC-014 containment contract (on-screen site only, ends on deactivation, badged, never archived); virtual loops a user-picked clip through WebAudio into a `MediaStreamAudioDestinationNode`. Audio+video requests are split in every mode, so the platform's combined CAMERA_AND_MICROPHONE resource never arises from a shimmed page |
| web-screen-sharing | per-site `getDisplayMedia`: no real-screen mode on any platform (a capture is whole-surface, so it would carry every other site); `screenShareMode` ask/virtual/block serves a picked image/video as the shared surface, top-frame only, never an audio track |
| web-push-notifications *(change)* | per-site `notificationsEnabled` toggle: JS Notification polyfill → flutter_local_notifications, auto-loads + skips per-instance pause for notif sites, any loaded notif site vetoes the app-background JS pause (NOTIF-011), iOS `beginBackgroundTask` grace + `BGAppRefreshTask` wake, Android mirrors via `WorkManager` periodic wake (no foreground service); a wake checks every notification site, live ones reloaded and the rest in a headless webview with the site's own posture (NOTIF-016), waits for the loads and posts for a site whose title unread count rose (NOTIF-013/014) |
| archive | passphrase-gated archived webspaces in a fixed slot pool; active state stays byte-identical when no archive is open |
| background-audio | per-site toggle: skips per-instance pause + app-background global JS pause (any-loaded veto), iOS `.playback` AVAudioSession + `audio` background mode; Android `mediaPlayback` foreground service + MediaStyle notification (BGAUDIO-006) driven by a page-JS media-session bridge; CI-tested via lifecycle injection + beaconing HTML fixture, plus a 3-tier notification gate (BGAUDIO-007: real-Chromium shim, channel contract, emulator assert on `getActiveNotifications()`) |
| block-statistics | persistent app-wide protection report: per-category daily buckets, 7/30-day ranges, all-time total in plaintext prefs; the itemised half (blocked hosts, per-site counts) in an AES blob keyed from the keychain; archive-tier sites excluded from both |
| webspaces | named site collections |
| webview-hints | color-scheme, matchMedia, theme prelude cache |
| webview-pause-lifecycle | per-instance vs process-global pause; "paused != frozen" |
| worker-shim-propagation | installs the per-site shims into Worker/SharedWorker scopes (blob wrapper); page and worker must report identical values |

## JS shim tests (jsdom + node:test)

Two layers, shared fixtures in `test/js_fixtures/` (see [README](test/js_fixtures/README.md)):

- **Dart** — `test/*_test.dart` asserts builder string output (cheap, only catches absent substrings).
- **Node** — `test/js/*.test.js` runs the dumped shim in jsdom, asserts post-injection JS state.

Workflow: edit shim in `lib/services/` → `fvm dart run tool/dump_shim_js.dart` → `fvm flutter test test/js_fixtures_drift_test.dart` (drift) → `npm run test:js` (behavior). Both run in CI (`build-and-test.yml`).

New shim: register in `buildAllFixtures()` in [tool/dump_shim_js.dart](tool/dump_shim_js.dart). Builders importing Flutter widgets (lib/main.dart, lib/screens/*) can't be reached — extract the JS string to a pure-Dart helper first.

**Shims that also run in workers** (anything in `workerScopeShims` in [webview.dart](lib/services/webview.dart) — see [worker-shim-propagation](openspec/specs/worker-shim-propagation/spec.md)) must be scope-agnostic: `globalThis` never `window`, navigator prototype via `Object.getPrototypeOf(navigator)` never `Navigator.prototype`, window-only sections (`Screen`, `document`, `matchMedia`, `RTCPeerConnection`, `plugins`/`getBattery`) guarded, and never *add* a property a real `WorkerNavigator` lacks. The payload is one script of concatenated IIFEs, so an uncaught `ReferenceError` in one silences every shim after it; `test/worker_shim_test.dart` gates this structurally.

jsdom has no canvas/WebGL/audio fingerprinting. Tests assert override **shape**, not engine behavior. Effects that need a real engine (canvas `captureStream`, Intl timezone math, real CSP, RTCPeerConnection semantics) go in the **browser tier** under `test/browser/` (Puppeteer + headless Chromium, `npm run test:browser`, run in CI's `validate` job). Use the `setupBrowser`/`requireBrowser`/`readFixture` helpers in [test/browser/helpers/launch.js](test/browser/helpers/launch.js) — the tier hard-fails when `CI=true` and no Chromium is found, and skips locally. Example: `camera_stream_real_engine.test.js` serves a page from `127.0.0.1` (getUserMedia needs a secure context), feeds the dumped camera shim a QR image, and asserts jsQR decodes it off the synthetic stream.

## Fastlane changelogs

Files under `fastlane/metadata/android/en-US/changelogs/<N>.txt` and sibling descriptions: **changelog + full description ≤ 500 bytes; short_description ≤ 80 bytes (no trailing dot)**. Run [scripts/validate_fastlane_metadata.sh](scripts/validate_fastlane_metadata.sh) before committing — oversize silently breaks F-Droid sync.

## Adding a new global app setting

A user-facing global pref is one entry of the `AppPref` enum; persistence, backup export/import, the demo-mode guard and the live value come with it.

1. Declare it in [lib/settings/app_prefs.dart](lib/settings/app_prefs.dart): `name('sharedPrefsKey', default)`, a `bool`, `int` or `String` (a const assert rejects anything else). Declaration order is the order a backup lists it.
2. Bind its row: a switch is `SettingTile(..., control: const PrefToggle(AppPref.name))`; anything else reads `AppPref.name.value` and writes `AppPref.name.set(v)`. Code with a side effect listens on `AppPref.name.listenable`; main.dart rebuilds on `AppPref.anyChange`.

- No per-pref constructor params, `_saveX` methods or second cache of the value: `set` persists (except in demo mode) and every reader sees the same notifier. `writeExportedAppPrefs` applies an import to disk and to the running app.
- The integrity test in [test/settings_backup_test.dart](test/settings_backup_test.dart) iterates `AppPref.values` — no test edit needed.
- Don't register: migration flags, download timestamps, cache indices, machine state from downloaded data (DNS blocklist, content blocker, localcdn).
- Per-site settings ride `WebViewModel.toJson` automatically — keep them on the model.
- Touched export/import? Re-run `flutter test test/settings_backup_test.dart test/settings_backup_compat_test.dart`.
- Import logic lives in `planSettingsImport` ([settings_import_engine.dart](lib/services/settings_import_engine.dart)); `_importSettings` only applies the plan (BACKUP-013).
- Renaming a persisted key (site JSON, backup field, SharedPreferences key) keeps reading the old name and carries the value over (for an `AppPref`, `legacyKey: 'old'`); dropping one is declared with its reason (`_renamedKeys` / `_retiredKeys` in the compat test, `RETIRED` in `test/js/prefs_key_history.test.js`). Both tests hold every release's writes against today's reads (BACKUP-012, BACKUP-014).
- A new `fromJson` field reads a wrong-typed value as absent, never with a bare cast: a site whose JSON throws is dropped at startup and deleted by the next save. An `AppPref` coerces its stored value itself; never read one with `prefs.getBool(AppPref.x.key)` and friends (gated by `test/js/prefs_key_history.test.js`).
- On release day (version bumped in `pubspec.yaml`), run `tool/backup_compat/generate.sh HEAD` and commit the new `test/fixtures/backup_compat/v<version>/`; the compat test fails without it.

## Settings rows: state in the subtitle, explanation in the hint

Spec: [openspec/specs/settings-hints/spec.md](openspec/specs/settings-hints/spec.md).
A settings row has three places text can go and they are not interchangeable.

- **Title** — what the setting is.
- **Subtitle** — what it is set to, or a status that moves: a value, a count,
  `Not configured`, `System`, `Forced off by Tracking Protection`. Often absent.
- **Hint** — what it does, what it costs, when to want it. A `HintButton`
  beside the title opens it as a dialog, at one icon of layout however long the
  text is.

Build the row from [lib/widgets/setting_tile.dart](lib/widgets/setting_tile.dart):
`SettingTile(title:, hint:, subtitle:, control:, lock:)`, or `HintedTitle` where
a row is not a list tile. `hint` is required (pass `null` for none), `control`
is `Toggle`/`Opens`/`Trailing`, and a row another setting decides takes a
`Lock` (`TrackingProtectionLock`, `ArchiveLock`, or `Lock.because(text)`),
which disables it and puts the reason in the subtitle. A mode picker
is a `ChoiceTile` labelled by a `switch` extension in
[lib/settings/setting_labels.dart](lib/settings/setting_labels.dart); a
per-site value that may follow the app-wide one is a `Scoped<T>`
(`FollowApp`/`Own`). Yes/no dialogs go through `confirm()`, SnackBars through
`toast` ([lib/widgets/toast.dart](lib/widgets/toast.dart)), and a screen with a
Save action mixes in `DirtyGuard` (a record snapshot), which
`test/js/site_settings_dirty_snapshot.test.js` enforces.

Explanation goes in the hint, never the subtitle. A sentence that is one tidy
line of English is four wrapped lines of Malay under a switch, and nothing
overflows, so no render test sees it — the list just goes ragged.

- A fixed-string `subtitle:` (one uninvoked `loc.<key>`, no branch) MUST stay
  under 90 chars **in every locale**, checked by
  [test/js/settings_hint_placement.test.js](test/js/settings_hint_placement.test.js).
  Over budget, move it into the hint — do not shorten the translation.
- State-derived subtitles (`cond ? loc.a : loc.b`, `loc.count(n)`) are exempt.
- Moving a description into a hint **renames** its ARB key
  (`<setting>Subtitle` → `<setting>Hint`) across all `lib/l10n/app_*.arb`,
  keeping every translation. Delete it instead only when an existing hint on
  the same row already says it.
- The hint dialog's title is the row's own title, and `HintedTitle` keeps the
  label `Flexible`. A bare `HintButton` is allowed only where it shares no row
  with a label (`test/js/settings_title_row_overflow.test.js` lists them).

## Adding user-facing strings (localization)

Spec: [openspec/specs/localization/spec.md](openspec/specs/localization/spec.md). UI strings go through `gen_l10n` ARB, never hardcoded literals.

- Add the key + a non-empty `description` (and `placeholders` for interpolation) to [lib/l10n/app_en.arb](lib/l10n/app_en.arb). Reference it via `AppLocalizations.of(context).<key>`.
- **Commit the 66 translated ARBs separately from the code** (see Git above): code + `app_en.arb` first, translations second, pushed together.
- Generated code lives in `lib/l10n/gen/` and is **gitignored** — regenerated by `generate: true` on `pub get`/build, or `fvm flutter gen-l10n`. Don't commit it.
- Pure-data display (e.g. `host:port`) goes into a local variable first; never a string literal inside `Text(`/`tooltip:` etc., or the LOC-002 guard fails.
- [test/js/l10n_no_hardcoded_text.test.js](test/js/l10n_no_hardcoded_text.test.js) and [design_tokens_no_literals](test/js/design_tokens_no_literals.test.js) scan every file under `lib/{main.dart,screens,widgets}`, so a new UI file needs no edit there. Each keeps a shrinking exemption list: drop a file from it once converted.
- Every key MUST carry a non-empty `description` (enforced by [test/js/l10n_coverage.test.js](test/js/l10n_coverage.test.js)) — that description is the context a translator/general model uses, so write it for someone who can't see the screen.
- To add a locale: hand `app_en.arb` (values + descriptions) to any general-purpose model, ask it to translate the values keeping `{placeholder}` tokens verbatim, save as `app_<locale>.arb`. No committed script or API key. Coverage (key + placeholder parity, no empties) is enforced by [test/js/l10n_coverage.test.js](test/js/l10n_coverage.test.js).
- Language identity (file actually written in its claimed language, not left in English or swapped) is enforced by [test/js/l10n_language.test.js](test/js/l10n_language.test.js) (runs under `npm run test:js`, no VRAM). Three checks, all backed by [test/js/helpers/l10n_language.js](test/js/helpers/l10n_language.js):
  - **Whole-file**: CLD3 via `cld3-asm` (pure WASM, no native build/model download) detects each file's language. Three benign code aliases (`he`→`iw`, `nb`→`no`, `bs`↔`hr`); a new locale needs an `ACCEPT` entry only if CLD3 reports a code other than its region-stripped stem.
  - **Han variant**: CLD3 reports both Chinese variants as `zh` and both are Han
    script, so a Traditional file shipped as Simplified passes every other check.
    `hanVariant()` counts variant-exclusive characters and requires each Chinese
    locale to carry its own. Exactly one Chinese locale ships and it is
    Traditional, under the base code `zh` (`zh` is BCP-47 for Chinese, not for
    Simplified) — gen_l10n cannot express a `zh_Hant`-only setup.
  - **Per-string**: flags individual values left untranslated (in English) when neighbours were translated — CLD3 is unreliable on single short strings, so this uses heuristics (non-Latin: a Latin-only multi-word value where the locale's script is expected; Latin: a value whose words are almost all English-source vocabulary plus an unambiguous English stopword). No allowlist — translate the offender. Run `node tool/check_l10n_language.js --per-string [locale]` for the report.
- Nested-webview rule applies to copy too: localized strings in `launchUrl`/`InAppWebViewScreen` flow through `BuildContext`, so resolve them at the call site.
- Widget tests pump a screen/widget through `pumpLocalized(tester, child)` or wrap it in `localizedApp(child)` ([test/helpers/localized.dart](test/helpers/localized.dart)); a bare `MaterialApp` leaves `AppLocalizations.of(context)` null.

## Touching the webspace archive

Spec: [openspec/specs/archive/spec.md](openspec/specs/archive/spec.md). Two rules that must hold for any change to archive code:

- **Active-state byte-identity (ARCH-001).** Everything persisted under the device-key path of `flutter_secure_storage` or in plaintext `SharedPreferences` MUST be byte-identical regardless of whether the device has zero or N archives where all are closed. No counter, flag, salt, MRU entry, or feature-touched marker may vary with archive presence or count. Settings export/import operates only on the app-tier collections and never serializes archive-tier state. Regression test: `test/archive_neutrality_test.dart` (asserts this invariant; update when you add app-tier state).
- **Per-site feature audit (ARCH-006).** When adding any new per-site feature, re-run the audit in the spec. Per-site features that touch disk, background scheduling, OS-level UI, or per-`siteId` entries outside the archive's MK keyspace MUST be disabled or routed through the archive MK for archive-tier sites — extend the override matrix in `WebViewModel` rather than handling it at call sites.

Argon2id derivation costs ~1s on target hardware. Keep it off the UI thread on startup paths and inside a "decrypting..." progress affordance on user-initiated unlocks.

## Adding a new credential / secret

Follow [openspec/specs/proxy-password-secure-storage/spec.md](openspec/specs/proxy-password-secure-storage/spec.md). Template: `ProxyPasswordSecureStorage`.

- **Storage**: a `SecureJsonStore` ([keystore.dart](lib/services/keystore.dart)) on `Keystores.credentials`, keyed by `siteId` (per-site) or a fixed reserved key (global). Never a new `FlutterSecureStorage` option set: on Apple the accessibility class is part of the keychain query, so changing it makes existing entries unreadable ([BUG-026](docs/bugs/026-aead-keys-unreadable-on-locked-wake.md)). An encrypted blob on disk takes its key from `KeychainAead`.
- **Never serialise to JSON**: `toJson` omits the field. No `includeSecrets` opt-in. Same rule as `isSecure=true` cookies. Backup files get emailed/synced — they must not carry secrets.
- **Hydrate on load** alongside per-site/global hydration in `SiteListStore.load` and `GlobalOutboundProxy.initialize`.
- **Migrate legacy plaintext** with the idempotent pre-pass in `ProxyPasswordSecureStorage.migrateLegacyPassword`.
- **Wire orphan cleanup**: add the store to `OrphanStore` in [orphan_sweep_engine.dart](lib/services/orphan_sweep_engine.dart) with its scope (session residue or configuration). `_OrphanSweepTargets` in main.dart does not compile until it sweeps the store; startup, post-import and post-delete all run the engine.
- **Tell the user post-import** (snackbar in `_importSettings`) if the related non-secret field was set — otherwise restored proxy silently fails auth.
- **Regression test**: assert the secret string never appears in `SettingsBackupService.exportToJson(...)` output. Template: "proxy passwords never appear in exports (PWD-005)".
- Update the spec, then `npx openspec validate --no-interactive --all`.

## Per-site web push notifications

`notificationsEnabled` (per-site) folds three behaviors so a single user toggle keeps notifications reliable:

- **Polyfill**: JS `Notification` constructor + `requestPermission()` are polyfilled at `DOCUMENT_START` (`ShimFrames.all`); calls bridge to `NotificationService` via `addJavaScriptHandler('webNotification', ...)`.
- **No per-instance pause**: `WebViewModel.pauseWebView()` early-returns for notification sites — iOS's `pauseTimers()` alert hack would freeze the JS thread between site switches and queue setTimeouts into one burst on resume.
- **No app-background JS pause while one is loaded** (NOTIF-011): Android's `pauseTimers()` is process-global, so any loaded notification site vetoes it, not only an active one.
- **Auto-load + retention priority**: notification sites are added to `SiteRuntime.loaded` on startup and tier `notification` in `SiteRetentionPriority` so OS memory pressure evicts other sites first.
- **iOS background contract** (NOTIF-005-I): `BackgroundTaskService` calls `UIApplication.beginBackgroundTask` on app-pause for a ~30s grace window and registers a `BGAppRefreshTask` (`org.codeberg.theoden8.webspace.notification-refresh`) that reloads notif sites opportunistically. Native bridge: [`ios/Runner/BackgroundTaskPlugin.swift`](ios/Runner/BackgroundTaskPlugin.swift).
- **A wake ends when its pages have loaded** (NOTIF-013): returning from `onBackgroundRefresh` completes the OS task, so `BackgroundSitesController.wake` awaits `BackgroundWakeEngine`, which waits for the reloads to settle. A reload shows what arrived but a site need not notify for it, so a site that stayed silent while its title's unread count rose gets one post on its behalf (NOTIF-014). iOS has no way to run a page between wakes: no foreground service, no Web Push in WKWebView apps, and keep-awake tricks fail App Store review.
- **A wake checks every notification site** (NOTIF-016), not only loaded ones with a webview: in a process the OS launched for the wake there is no webview at all. `BackgroundWakeEngine.plan` decides from `wakeCandidateFor` (live: reload; else `WebViewFactory.openHeadlessCheck` with `WebViewModel.headlessCheckConfig`, held to `getWebView` by `test/js/headless_check_config_parity.test.js`; else skip with a `WakeSkip` reason). Lineage: [BUG-024](docs/bugs/024-background-notifications-never-arrive.md).
- **Android background contract** (NOTIF-005-A): same `BackgroundTaskService` — Android side uses `WorkManager` `PeriodicWorkRequest` (15-min minimum, 15-min initial delay so the first period is not due at enqueue time, unique-work `webspace-notification-refresh`) and no foreground service: apps that notify from the background are woken by a push channel rather than staying resident, and `FOREGROUND_SERVICE_SPECIAL_USE` is intractable for Play review. A keep-alive `specialUse` service was built and withdrawn for this reason: a foreground service for notifications is off limits (NOTIF-015, gated by `test/js/notification_no_foreground_service.test.js`). When no Flutter engine is reachable the worker starts one with no activity (`WorkerFlutterEngine`, plugins from `EnginePlugins`, `main` told by `--background-wake` to build no site webview), waits for Dart's `backgroundRefreshReady`, and destroys it after; `MainActivity.provideFlutterEngine` stops it first if the app is opened. Native bridge: [`android/app/src/main/kotlin/.../BackgroundTaskAndroidPlugin.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/BackgroundTaskAndroidPlugin.kt) + [`NotificationRefreshWorker.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/NotificationRefreshWorker.kt). One-time background-limits info dialog shows on first toggle on either platform. The CI lifecycle tier runs the worker through `NotificationRefreshDebugReceiver` (`android/app/src/debug/`, debug builds only) — `cmd jobscheduler run -f` cannot drive periodic work, since WorkManager refuses a `WorkSpec` executed before its next run time.
- **Test delivery the way sites deliver** (NOTIF-012): a fixture that posts on page load proves only that a reload happened. Scenario P in the lifecycle tier serves a page whose unread count lives on the server and which posts only when the server sends it something; it checks the live path with the site behind a plain one, then records a message while the app sits in the background past the freezer, drives the wake, and requires the wake's fallback post.

When adding a notification-related code path, prefer extending `NotificationService` / `BackgroundTaskService` / [`BackgroundSitesController`](lib/controllers/background_sites_controller.dart) over reaching into `_WebSpacePageState`.

## Per-site toggles backed by downloaded data

DNS blocklist, content blocker, LocalCDN need a downloaded blob.

- **Per-site strength**: both blockers are also adjustable per site, as masks over the app-wide configuration — `WebViewModel.dnsBlockLevel` (null = follow the app level) and `disabledFilterLists`. A mask can only relax: a level's list is fetched on demand and falls back to the app level until it lands, and a filter list not enabled app-wide is not in the engine at all. **The Hagezi levels do not nest** (21,921 of 297,756 domains drop out of a higher level), so each domain carries a bit per level that names it rather than a single "lowest level"; anything else makes the app-wide level's behaviour depend on which per-site levels were downloaded. See [dns_level_mask_engine.dart](lib/services/dns_level_mask_engine.dart) and [filter_list_mask.dart](lib/services/filter_list_mask.dart).
- **DNS blocklist / content blocker**: the switch stays interactive when the service has no data. Enabling it flips the setting (it takes effect once the data is downloaded) and fires `_warnNotConfigured` — a SnackBar naming the feature and pointing at App Settings. Tracking Protection's toggle fires the same warning for each unconfigured feature it forces on. While a blocker is effectively on without data, its row sets `SettingTile.missingData`: a warning icon beside the title and an amber "Not configured" subtitle (also on the Tracking Protection card when a forced dep is unconfigured).
- **LocalCDN**: still hard-gated by a `Lock` — it can't serve anything without a cache, so the switch is greyed and its `value` forced off.
- See [lib/screens/site_privacy.dart](lib/screens/site_privacy.dart): `DnsBlockService.hasBlocklist`, `ContentBlockerService.hasRules`, `LocalCdnService.hasCache`.
- **App Settings rows for the data**: each dataset is a `DownloadableDataset` adapter in [lib/widgets/datasets.dart](lib/widgets/datasets.dart) rendered by one `DatasetTile`, which owns the busy state, the date line, the buttons and the SnackBar. A new downloaded dataset is a new adapter, not a new row.

## Per-site settings MUST apply to nested webviews

Every webview that runs as a site (its own, the nested `InAppWebViewScreen` a
cross-domain link opens, a popup either spawns, the headless check a
background wake opens) is built from one `SitePosture`
([lib/services/site_posture.dart](lib/services/site_posture.dart)), resolved by
`WebViewModel.sitePosture` and handed whole through `LaunchUrlFunc` →
`launchUrl` → `InAppWebViewScreen` → `WebViewConfig`. Every field is required
with no default, so a field the chain forgets does not compile, and a hostile
outbound link cannot drop the site's posture. Spec: NESTED-010; history:
[BUG-024](docs/bugs/024-nested-posture-drift.md).

When you add a per-site field:

1. `WebViewModel.toJson`/`fromJson`.
2. A field in the matching `SitePosture` group, resolved in
   `WebViewModel.sitePosture` ([lib/web_view_model.dart](lib/web_view_model.dart)).
   An archive-tier or Tracking Protection override is applied there, through
   an `effective*` getter, never at a consumer. The rule itself lives in
   [lib/services/site_overrides.dart](lib/services/site_overrides.dart), which
   the settings screens also read, so a screen shows what the webview runs.
3. Its consumer reads `config.posture.<group>.<field>` (the factory in
   [webview.dart](lib/services/webview.dart)) or `widget.posture` (the nested
   screen).

A nested screen differs from the site's own webview only where
`SitePosture.forNested()` says so. Wiring that belongs to a surface rather than
the site (callbacks, `backForwardGestures`, the slot's `backgroundAudioEnabled`,
the site icon and search targets) stays a `WebViewConfig` field the owning
surface sets. What the host answers (prompts, popups, capture resolvers,
cookie jars, routing) is one `WebViewHostHooks`
([webview_host_hooks.dart](lib/services/webview_host_hooks.dart)) that
`main.dart` builds once and both surfaces take whole; a new host answer is a
required field there (BUG-027).

If the field controls JS in `initialUserScripts`, inject it with `pageShim(..., frames: ShimFrames.all)` ([page_shim.dart](lib/services/page_shim.dart)) so the shim reaches cross-origin iframes.

## Logic engine vs rendering engine

Orchestration (which sites unload on switch, how indices shift after delete, what cookies move during activation) → pure-Dart engine in `lib/services/*_engine.dart`. Template: [cookie_isolation.dart](lib/services/cookie_isolation.dart). Native webview / platform channels / `setState` stays at the call site.

- Mutating `SiteRuntime`'s models, loaded positions or webspaces with >1 line of index arithmetic? Engine.
- Which loaded sites go, and why? A `ResidencyEvent` case in `SiteUnloadEngine.plan` ([site_unload_engine.dart](lib/services/site_unload_engine.dart)), run by `SiteUnloadEngine.apply`; every eviction picks through `evictionOrder`. Never unload from a loop at a call site.
- `await native_call` then mutate shared state with scenario-dependent logic? Engine.
- Engines never `import 'package:flutter/material.dart'`, never call `setState`, never touch `context`. Add interfaces on existing services (e.g. `CookieManager`) instead of reaching into concrete types.
- Race protection: pass `(versionAtEntry, int Function() currentVersion)` so the engine can bail without knowing about widget state.
- Tests import the engine directly with in-memory fakes that **model the interface** (e.g. `MockCookieManager` modeling RFC 6265 domain-match), not trivial stubs. See [test/cookie_isolation_integration_test.dart](test/cookie_isolation_integration_test.dart).
- One fake per interface, in [test/helpers/](test/helpers/) (`MockCookieManager`, `MockFlutterSecureStorage`, `FakeTorRuntime`, `FakeOutbound`, `FakePathProvider`, `FakeWebViewController`). Extend it when a test needs a new knob; never redefine it in a test file, and never import another `*_test.dart` for its fakes.

## Adding native code that mutates shared state (BUG-007)

A recurring class: native state touched by a callback / IO thread AND another path,
with only *partial* synchronization (which looks safe and isn't). It has recurred across
Rust/JNI (adblock UAF), Swift (BGTask double-complete), and Kotlin (intercept cache). Full
lineage + the invariant: [docs/bugs/007-native-shared-state-races.md](docs/bugs/007-native-shared-state-races.md).

When you add native state (a Kotlin plugin field, a Swift property, a Rust handle) that any
callback, `expirationHandler`, WorkManager/coroutine, or chromium sub-resource IO thread can
observe:

- **Total synchronization or none-shared.** Either single-owner / immutable-snapshot /
  message-passed, or *every* read, write, and eviction under one monitor / serial queue /
  RW-lock. A lock on the writer but not the reader is BUG-007 — don't. In Kotlin that means
  [`Guarded<T>`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/Guarded.kt)
  (state reachable only inside `with { }`), `SiteEventInbox` for IO-thread events Dart
  drains, or an immutable snapshot behind a `@Volatile var`;
  [`test/js/native_shared_state.test.js`](test/js/native_shared_state.test.js) fails on any
  other property holding a mutable collection, and on a raw lock, unless it is named there
  with its reason.
- **One-shot resources are idempotent + identity-guarded.** A freed pointer or a completed
  task: guard the second call to a no-op (`guard pendingRefreshTask === task`). Never
  free/complete by re-reading shared state.
- **Read-heavy hot path → RW-lock** (readers concurrent, writer exclusive); don't hold a lock
  across a blocking call (read under lock, compute outside, write under lock).
- **Encode a class-level guard** (practice, not optional): a JVM concurrency/stress test or a
  structural CI gate so the *next* instance fails, not just this one. Templates:
  `AdblockEngineNativeTest.kt`, `SiteEventInboxTest.kt`,
  `test/js/native_bgtask_completion_funnel.test.js`.
- **Record recurrence in BUG-007**, not a new file — append a dated fix attempt with *why it
  was partial* (which path it covered, which it missed). Cross-link the spec that owns the
  state.

## DRY: tests delegate, don't reimplement

Test harness re-implementing `switchToSite`/`deleteSite` = un-extracted engine. Wrap the real engine; never re-write the flow in a test. See `CookieIsolationTestHarness` in [test/cookie_isolation_integration_test.dart](test/cookie_isolation_integration_test.dart), whose deletion goes through `SiteListState` ([test/helpers/site_list_state.dart](test/helpers/site_list_state.dart)) and so through `SiteLifecycleEngine`.

## Code flows new → stable

New features extend the engine (or add one alongside). Never inline a feature-specific branch into a stable call site; never copy stable engine logic into a new-feature path. A `_WebSpacePageState` method reads as engine calls + persistence/UI side-effects.

## UI race conditions

Async UI handlers (button callbacks, `onPopInvokedWithResult`, gestures) get re-entered before the first call resolves.

- **Rapid input**: a handler that `await`s before acting can be entered twice concurrently.
- **Guard**: a [`ReentryGuard`](lib/services/reentry_guard.dart) field, `await _guard.run(() async {...})`; `run` owns the `finally`, so no exit path leaves it held.
- **State across awaits**: re-check `mounted`, indices, shared state — another handler may have mutated.
- **Drawer/dialog flash**: opening UI in an unguarded async callback lets a second tap close it immediately.
