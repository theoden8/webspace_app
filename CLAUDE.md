# CLAUDE.md

WebSpace: Flutter app managing multiple websites with per-site cookie isolation via flutter_inappwebview. Platforms: iOS, Android, macOS, Linux (WPE WebKit fork).

## Coding principles

Simplicity comes first: every structure here exists to make the code easier to hold in the head; one that makes it harder has failed, however correct it is. Within that: one owner per fact, joins are types, and every invariant is caught at the earliest point it can be violated. A bug then has one suspect.

Reasoning stays local as the system grows. Adding a component costs the same to write, to read and to check, whatever else exists. Components meet only through what they share, so the first question for any new piece is what it shares with the rest, and a good answer is small and explicit. Interleavings multiply with every component that touches the same state: two pieces that share nothing can be understood and checked apart, and two that share a variable must be understood and checked together. A design in which every new piece interacts with every old one has stopped scaling, however correct each piece is.

Design is proved by the compiler and timing by the model checker, each over its own unit: a type for a fact, and for timing what runs between two awaits. The model is printed from the code, so when the two disagree the suspects are the code, the printer and the fakes, never the printed text, and the trace names which. A check counts once it has caught a planted mistake, and the mistake stays as its proof. Debt is a list in a gate that only shrinks. Verification only grows: a refactor prints the same model and still catches every planted mistake, no count of checks, mistakes caught or obligations proved falls ([`formal/levels.tsv`](formal/levels.tsv)), and a check retires only when its replacement has caught the same mistakes.

### The ladder

Each invariant sits on one rung. Put it on the highest rung Dart allows; step down only with a one-line reason next to the check.

| Rung | Caught by | Dart form |
|---|---|---|
| 0 | decided before run time | `const` data; `extension type` ids; enum with fields; one field registry every serializer iterates |
| 1 | the compiler, or the analyzer at error severity | `sealed` + exhaustive `switch`, no `default` or `_`; records with `required` fields; a scope object that does in the constructor and undoes in `dispose`; a rule in [`tool/webspace_lints`](tool/webspace_lints) for what a type cannot say |
| 2 | an assert at the owner | `assert(cond, 'why')` on entry to the compartment that owns the fact |
| 3 | a self-check | the owner recomputes its result independently and compares |
| 4 | a boundary test | the compartment driven through its public type with a fake that models the other side |
| 5 | a gate | a test over source text; its header says what a type could not express |
| 6 | prose | a paragraph here or a doc comment; catches nothing |

An invariant written as a comment is on rung 6. `tab_lifecycle_engine.dart` says in a `///` that a tree has "an `activeTabId` that names a member"; as `assert(tabs.any((t) => t.id == activeTabId), 'activeTabId names a member')` the comment goes. A swallowed error (`catch (_)`) is below rung 6.

**Check**: break the invariant on purpose. If a reviewer or a grep is what catches it, it is on the wrong rung.

### Rules

1. **One owner.** A fact is computed in one place; everything else reads it. Two places agreeing today is still a bug. The UI never restates a rule. A decision has one owner too: a job this codebase already does (a guard, a dialog, a store, a "follow app" choice, a sync primitive) is done the way the map or the existing code does it. A second way needs one line saying why, and then replaces the first everywhere in the same change, or is listed as debt. *Check*: a bug fix that edits two compartments means the fact had two owners; a new idiom beside an old one for the same job is a fork; fix the ownership.
2. **Small typed joins.** Between compartments passes a record, class or sealed type, never a parameter list, map or string. More than four parameters is a missing type. A call names its arguments: parameters are named (`required` where there is no default), so the call site says what each value is, a reordered parameter cannot shift meaning, and an inserted one fails to compile until every call names it. Positional only where the signature is fixed from outside (an override, a Flutter callback type, an operator) or for one leading argument the function's name already names (`Host(raw)`, `messenger.toast(message)`, `LogTag.x.debug(message)`, a `BuildContext`); never a `bool`, never two of one type. A reader needs about four entities to follow a change; more means a join is misplaced. An abstraction earns its place by removing a copy, a forgotten-item failure or a parameter list; one that only adds a hop (a single caller, a generic parameter nobody varies, a wrapper that renames) is inlined. Every hop is a join that has to be proven valid too (a type, an assert, a boundary test), so an unneeded one is paid for twice: once in reading, once in validation. *Check*: did a join in the map change shape? One line why. A positional parameter past the first, or a positional `bool`? `webspace_lints`' `positional_parameters` rule reports it as an analyzer error; a declaration its own library tears off into a parameter or a typedef declared outside the package (`List.sort`, `ValueChanged<bool>`) is exempt by that use, so no list of exemptions is kept.
3. **Fixed cost per axis.** Adding one item (a per-site field, a pref, a capture kind, a settings row) touches a fixed set of places through one funnel, and forgetting it anywhere fails to compile. *Check*: edit sites against the budget table; over budget, build the funnel first in its own commit.
4. **Layers point down.** UI → model → services → values → platform (the map lists the directories). A file imports its own layer or lower. Engines (`*_engine.dart`) decide and are pure: no Flutter import, no I/O, no `context`; tests import them with fakes that model the interface. *Check*: [`test/js/layers.test.js`](test/js/layers.test.js) (rung 5: Dart has no module boundary a type can enforce); its debt list only shrinks.
5. **Ids are types.** `extension type SiteId._(String raw) implements String`; a `String siteId` parameter is a square where a move was meant (`SiteId` in `settings/site_ids.dart` and `Host` in `services/url_host.dart` are the model). Constant data is `const`; a field is declared once and every serializer iterates the declaration. A list of what a compartment declares (its variables, its operators, its tables, a record's fields) is the declaration's own enumeration, an enum's `values` or a `switch` over it the compiler holds exhaustive, never a hand-written list beside it: a hand list is right where it is written and wrong where the declaration grows, and nothing says so, so a component's validity would change at its callers. *Check*: any new `String` id, startup-built table, hand-written per-field line, or a list that restates an enum?

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
| `SitePosture` (`services/site_posture.dart`) | a site's resolved settings in six groups, resolved once by `WebViewModel.sitePosture` | `LaunchUrlFunc(url, posture:, homeTitle:)`; `WebViewConfig.posture` |
| `site_overrides.dart` | archive-tier and Tracking Protection overrides | `TrackingProtectionForce`, `ArchiveFold`; read through `effective*` getters and by screens |
| `WebViewHostHooks`, `SiteHooks` (`web_view_model_hooks.dart`) | the host's answers to every webview that runs as a site: prompts, popups, capture; and to a site's own webview, those that name the site (on screen, its outbound links, its link menu) | one required-field class each, passed whole; `SiteHooks(host:, ...)` to `getWebView` |
| `BlockDecision` | whether a request is blocked, and by which blocker | `decide(BlockQuery)` → sealed `BlockVerdict` |
| `PopupKind` (`services/popup_webview.dart`) | which window a page asks for opens as a real popup (a captcha; a sign-in host where the site's sign-in popups are on, NESTED-014) and which hosts besides the site's that popup may show; whether this host offers sign-in popups (always but on Android, where the experiment does) and a site's resolved choice | `PopupKind.signInOpens(choice:)` → `SitePage.signInPopups`; `PopupKind.forWindow(url, siteUrl:, signInPopups:)` in `onCreateWindow`; `showPopup(windowId, url:, kind:)`; `onSiteNavigationPolicy(..., popup:)` |
| `NavigationBoundary` (`services/navigation_decision_engine.dart`) | the site's declared and initial resolved domains; the redirect exception ends when its first document commits | `WebViewConfig.navigationBoundary`, shared by native callbacks and navigation decisions |
| `WebViewModelDomains` (`web_view_model_domains.dart`) | a site's explicit domain claims or its implicit home-domain claim | `effectiveDomainClaims`, `matchesSiteClaim(url)` |
| `redirectDomainClaim` (`services/redirect_domain_engine.dart`) | which externally handled first-load destination can become the home, using the navigation decision and routing validator | `NavigationDecision` + `RoutableSite` + resolved URL + other sites → `DomainClaim?`; `SiteEditingController.offerRedirectHome` asks and persists |
| `planExtensionAttach`, `WebExtensionLibrary` (`services/web_extension_attach_engine.dart`, `services/web_extension_library.dart`) | which imported web extensions a site's webviews load, from which folder and with what grants, or why none (WEBEXT-016): the site's own choice for each, else the extension's default for every site (WEBEXT-004); whether extensions are offered here (`webExtensionsOffered`); the extensions imported on this device, their folders and what WebKit reported reading each (WEBEXT-003); where a site's extensions keep their data and open their pages (`ExtensionHome`: its plan in its container, none for an incognito site) and which pages it offers (WEBEXT-008); a removal that stops an extension everywhere and deletes its data in every container (WEBEXT-002); how a backup carries the library, by reference or with files, each sized, and an import's relink by fingerprint (WEBEXT-011, `web_extension_backup_engine.dart`); an extension added from a link, its source, its update check, asked for or daily once the user switches it on and an update installed over it under the same id, read again by its revision (WEBEXT-017, WEBEXT-018, `web_extension_source_engine.dart`) | `WebViewModel.extensionPlan` → `SitePage.extensions` → `nativeExtensions` into the fork's `webExtensions`; `WebExtensionLibrary.instance.add(package)` / `.remove(id)`; `site.extensionHome(isolation)` → `.offering(page, home:)`, `.open(page, extension:, home:)`; `.carryOffer()` → `BackupPrompts.chooseExtensionCarry`, `.restoreFromBackup(section, confirmAdd:)`; `.latest(source)`, `.download(candidate)`, `.add(package, source:)`, `.checkUpdates(now:, because: CheckReason)`, `.prepareUpdate(id)` → sealed `UpdatePrepared`, `.install(id, package:)`; every fetch through `fetchViaAppProxy`; the fork's calls through one `ExtensionEngine` (`services/web_extension_native.dart`) |
| `launcherTileIcon` (`services/launcher_tile_engine.dart`) | a home screen tile's icon: the site icon on an opaque plate, white unless the icon is lost on white, full bleed so a launcher adds no background of its own (HS-018) | `ShortcutService.tileArguments`, through which every tile's icon reaches native; `plateFor(image)` → `TilePlate` |
| `ContentRuleLists` (`services/content_rule_lists.dart`) | which compiled WebKit content rule lists a new webview attaches (CB-020) | `contentRuleListIdentifiers`; `planRuleLists` → sealed `RuleListPlan` |
| `pageShim` (`services/page_shim.dart`) | how a page shim is injected | `pageShim(group, js:, frames:)`; `ShimFrames` has no default |
| `site_unload_engine.dart` | which steps an unload runs | `enum UnloadReason` |
| `OrphanSweepEngine` | the one orphan sweep and its store list | `enum OrphanStore` |
| `CaptureKind` / `GrantStore` (`settings/capture.dart`, `services/media_grant_engine.dart`) | capture kinds and their grants | enum over three mode enums, `grantOf`/`withGrant` switches; sealed `GrantStore` |
| `ScreenShare` (`services/screen_share.dart`), `ScreenSharePlugin` / `ScreenShareService` (Android), `ScreenSharePlugin` (macOS), `screen_share.cc` (Linux) | the one live share of the device screen: the webview it was started for, its frames, and every way it ends (SHARE-017, SHARE-018) | `ScreenShare.instance.start(owner, request:, notice:)` from the share bridge (`ShareHandlers`); `.endSite(site)` in `stopRealCapture`, `.endView(view)` on a main-frame load; `sharing(site)` keeps the site running in the background |
| `AppPref` (`settings/app_prefs.dart`) | every global pref, its default, what a backup carries | `AppPref.x.value` / `.set(v)`; backups iterate `AppPref.values` |
| `SiteField` (`settings/site_field.dart`) | every key a site's JSON carries, its older names, and whether a QR share carries it | an exhaustive `switch` each for save and read in `web_view_model_json.dart`; `SiteSettingsQrCodec.includedKeys` and the compat test iterate `SiteField.values` |
| `SecureJsonStore` / `Keystores` / `KeychainAead` | secrets at rest and their keychain options | `SecureJsonStore<T>` on a `Keystores` set |
| `host_platform` (`platform/`) | dart:io primitives, importable from plain Dart | conditional export |
| `ShellStore` (`controllers/shell_store.dart`) | what the page saves beside its sites: theme, global user scripts, suggested sites, webspaces, the site on screen | `_shell.theme` etc.; `save*` per value |
| `SiteActivationController`, running `ActivationTable` (`controllers/activation_table.dart`) | which site is on screen, and the residency, capture and teardown that move with it; a site loaded off screen (`preload`); a nested screen that runs as a site beside them (`openNested`, the model's `nested`); a webspace switch's unloads (`switchWebspace`, WEBSPACE-013); a site a reset sends home or a revoked certificate unloads (`unload`) | `activate(WebViewModel?)` (null shows the webspace list), `preload(siteId)`, `openNested(site, opening:)`, `switchWebspace(leaving:)`, `unload(site, reason:)`; talks back through `ActivationHost` and a `NestedScreenHost` (`controllers/activation_host.dart`) |
| `SiteSetCommit` (`controllers/site_set_commit.dart`) | the order every change to the set of sites runs its steps in; which steps a change needs is `SiteSetChange.effects`, and a site that leaves the list leaves the loaded set, the screen and its webview in `SiteRuntime.apply` | `commit(change)`, or `stage(change)` where a table's step lands it in its own turn (`SiteSetStage`: `prepare`, `land(commit:)`, `follow`); talks back through `SiteSetCommitHost`, which the page and the walk implement |
| `SiteDeletion` (`controllers/site_deletion.dart`) | a site's delete, in the order an archive's close keeps: the commit takes it off the list, the frame unmounts its webview, then its container goes (CONT-010) | `delete(site)`; talks back through `SiteDeletionHost` |
| `ReentryGuard` | one run of an async UI handler at a time | `guard.run(() async {...})` |
| `KeyboardShortcuts` (`services/keyboard_shortcuts.dart`), `KeyboardShortcutController` (`controllers/keyboard_shortcut_controller.dart`) | which desktop key asks for which action, taken before the focused widget (Linux's webview keeps every key) for the screen on top; the page's answers, each the menu's, the strip's or the Tabs sheet's, and the nested screen's own (NAV-014) | `KeyboardShortcut.keys(mac:)` → sealed `KeyboardShortcut`; a `ShortcutScreen` answers `answerShortcut(shortcut)`; the page's talks back through `KeyboardShortcutHost`; menus name a key with `shortcutLabel<T>` |
| `LauncherLift` (`widgets/launcher_lift.dart`) | how an icon in a launcher grid is pressed: a tap opens it, a long press lifts it, let go in place for its menu, moved onto another to take its place | `LauncherLift(data:, onOpen:, onMenu:, onDrop:, child:)`; menus through `showLauncherMenu`; its grid is a `LauncherGrid` (`widgets/launcher_grid.dart`), whose `LauncherCell`s take a hovering icon and make room, the one way a launcher grid reorders (the library's and the drawer's); its place a `LauncherSlot` (`widgets/launcher_slot.dart`), which slides it wherever the grid moves it; a grid that turns into rows, or packs into more columns, lays its places out through `LauncherMorph` between two layouts, its slots going with them (`morphing:`); where a level's items go is `LibraryLayout.place(count:, room:)` (`settings/library_layout.dart`), Automatic packing them as the drawer does, and each tile through `LauncherMorphTile` (`widgets/launcher_row.dart`), which owns where the well sits on the way |
| `WebspaceName` (`widgets/webspace_name.dart`) | how a webspace's name shows wherever it shows: led by the glyph the user picked (`WebspaceGlyph`, saved by name on the `Webspace`), whose picture and spoken name are exhaustive switches | `WebspaceName(webspace, style:)`; `glyph.icon`, `glyph.label(loc)`; `pickWebspaceGlyph(context, current:)`; an open folder's, renamed in place, `EditableWebspaceName(webspace, style:, onRetitle:)` → `WebspacesController.retitle(id, to: WebspaceTitle)` |
| `LaunchZoom` (`widgets/launch_zoom.dart`) | a site's card between its library icon and the screen, over the switch until the switch shows (capped by `Motion.launchHold`); the card a hold on the site's top bar lifts and the finger carries, and whether its let-go closes (`LibraryStyle.pullCloses`, the open folder's too) | `LaunchZoom(sites:, area:)`, where sites show, which a card with no icon to grow from covers; `open(site, from:, to: CardSwitch)`, `close(site, to: CardLanding)`, `hold(site, at:, to:, back:)` → `CardHold`, asked by the top bar's `CardHandle`; the page's every switch goes through `_throughCard`; the icon from `WebspaceLibraryState.siteWell` |
| `RuntimeVars` / `Shared<T>` (`services/runtime_vars.dart`, `services/step_table.dart`) | the model's variables the runtime owns (`loaded`, `current`, `version`, `marker`, `nested`, `headless`, `fore`), read anywhere, written only by a table's `Write` (`Mutable.over`), by `apply` and by `retired`, those two with a `Commit`, so a write outside a table's arm has no handle; and the model's operators over them alone (`Evictable`, `Pages`, `Running`), each a `Def` that runs there and prints; a test starts from `seed` | `_sites.vars.loaded`; `host.vars.isEvictable(site)`; `Mutable.over('loaded', of: (c) => c.world.host.vars.loaded)` |
| `Commit`, `SharedAt`, `CommitView` (`services/step_table.dart`) | that a write of the model's state the code holds runs in a step's turn: only the runner makes a `Commit`, for an arm's writes and for an `Act`'s or a `Call`'s `then` (a `CommitView`), `commitInput` for an input marked by hand, `Commit.environment(Environment)` for a write of an environment action `activation.tla` states by hand (the frame's bind and take), and `Commit.unmodeled(Unmodeled)` names a write no step takes yet (a rebuild, a renderer gone among them), so a write outside them does not compile (`test/declare_to_use_test.dart`); `UnmodeledWrites` stamps each such write, and a step that reads a stamped variable once its flow's await is over records a meet, a timing TLC did not check, which the walks and schedules hold to `owedMeets` (`test/helpers/walk/unmodeled_meets.dart`) | `WebViewModel.tabsCell.write(at:, to:, commit:)`, `Indexed.over(variable, cell:)`; `tabBinding.queue(bytes, tab:, commit: c.commit)`; `model.disposeWebView(commit:)`; `SiteRuntime.apply(change, commit:)` |
| `StepView`, `Port`, `Constant` (`services/step_table.dart`) | what a table's own code reaches of its engine's world: the flow's fields and the leaves, constants and ports its table declares, each port naming the model's variables it reads and changes, so an undeclared access does not compile (`test/declare_to_use_test.dart`), and what its own code reads held to its `reads:` from the resolved AST (`test/port_reads_test.dart`); an `Expr` is made only by the core's combinators and its named kinds (`Expr.op` and `Expr.handPaired` for text written beside code, `Expr.checked` for an engine's value asserted equal to the printed rule, `Expr.chosen` for an engine's choice among a `Pick`'s, `unwrapped`), and a `Def` asked of values in hand is `evaluate(world, args:)`; a run beside a text names its `HandPaired` value (`services/hand_paired.dart`), one per site, so the code's hand pairings are an enum that only shrinks | `Port(name, reads:, changes:, of:)`; `port.from(c)` in a guard or an effect, `Call.on(port, run: (c) => c.api..., writes:)` and `field.receivesOn(port, ...)` for a call, whose writes the port must change; `Constant('Name', read: (w) => ...).value` |
| `Reads`, `BaseOp`, `RowRead`, `Need` (`services/model_names.dart`) | what a value of a step reads of the shared state: each leaf its variable, each operator the union of its operands', a hand-written string what it names, and the fields of other flows' rows it reads, by kind; what it needs of the model's constants (`Need`), necessary and held to every world's coverage; an action's footprint is a function of these and of the kinds its row can hold, read off the arms, printed as `activation_footprints.tsv` and held to the printed text by `formal/footprint.py` and to what each step reads as it runs by the walks (`StepReads`), a flow's own `fl` row being its own | `Expr.op(HandPaired.x, tla:, run:, reads: const Reads(vars: {...}))`; `Expr.inFlight(FlowKind.dns, run:)`; `StepTable.footprints()` |
| `ModelVar`, `FlowField`, `ModelDef`, `ModelConst` (`services/model_names.dart`) | the model's variables, a flow's fields, the engines' operators and the model's constants, each named once: every leaf, `Field`, `Def` and constant leaf (`Constant`, `Members`, `Indexed.fixed`, `Expr.ofConstant`) takes its name there, and the printer iterates them (`activation_vars`, each action's frame, `activation_ops`), so a declaration left out of a registry cannot happen | `Var(ModelVar.loaded, ...)`, `Field(FlowField.site)`, `Def(ModelDef.capture, ...)`; `definition(ModelDef)` in `test/formal_model/models.dart` |
| `TabVars` (`controllers/tab_vars.dart`), `tab_leaves.dart` (services) | the tabs' variables of the model (`tabs`, `active`, `host`, `built`, `hist`, `queued`, `file`; `link` is `TabsController.linkHosts`) as the code reads them, the platform-held ones by name from an engine, and the rules over them (`RunsAs`, `Capture`, `Bound`, `Shown`, `Taken`, `Staged`) the activation, the proxy rules and the tab tables write and read with | `TabVars.framed(site)`, `TabVars.rebound(site, tab:, label:, loaded:)`; `webViewGone(site)`, `captured(site)` from an engine |
| `NavCapture` / `captureSteps` (`services/nav_capture.dart`) | a capture of a site's back stack as its two awaits, keyed by the tab its webview was built for as it began and dropped when that tab closed or moved before the webview answered (TAB-003), and its file taken back when the tab closed or moved while the save was out (BUG-036); every flow that captures places the same steps | `beginNavCapture(model)` on the hosts; `captureSteps(names:, places:, of:)` in a table; a world that captures is `Capturing` |
| `JarTurn` (`services/cookie_isolation.dart`) | that the running code holds the shared jar's turn (ISO-003): only the engine's `_turn` makes one, and every read of the jar it saves and every write it makes takes one, so code outside a turn cannot reach them; a table's steps find it on their world | `_snapshot(turn, of:)`, `_empty(turn)`, `_setCookies(turn, site:, cookies:)`, `_loadStored` / `_saveStored(turn, site:)` |
| `LockOrder` (`utils/concurrency.dart`) | deadlock freedom of every primitive that makes a caller wait: no wait on what the running code holds, no lock order seen both ways; `SerialQueue`, `SingleFlight` and the tab gate take part | `SerialQueue('name').run` / `.enqueue`; a member that runs in the turn is marked `@Held(#queue)`, which `webspace_lints`' `held_in_turn` rule holds |
| `PageJs` (`services/page_js.dart`) | every script the app runs in a page (`lib/js/`), and how a value reaches one | `PageJs.x.script`; `PageJs.x.withConfig({...})`; shared parts by `// @include` |
| `LogTag` (`services/log_service.dart`) | every log tag and the label it shows | `LogTag.x.debug(msg, sensitive: true)`; `LogService.log` takes a `LogTag` |
| `ViewBlockers` / `DnsTable` (`services/view_blockers.dart`, `services/dns_block_service.dart`) | the DNS level each live site webview's native interceptor was told (the model's `told`), and every user-driven write of the DNS lists and the app-wide level (a download, a level a site asks for, the clear) as a step table whose one write tells the views (DNS-022) | `WebInterceptNative.attachToView(DnsBlockService.instance.views.built(view, site:, siteLevel:, localCdn:, contentBlock:))`, the `ViewAttach` the build sends, and `.gone(view)`; a headless check's `attachToHeadless(headless, blockers:)`; `downloadList` / `downloadLevel` run `DnsBlockService.table` |
| `FileDialog`, `socksConnect`, `engineImage`, `ProxyRefused`, `TorRuntimeFailure`, `FileStore` (`services/file_dialog.dart`, `socks_connect.dart`, `engine_image.dart`, `proxy_refused.dart`, `tor_engine.dart`, `file_store.dart`) | what a platform or third-party call fails with, named once where the app calls it: the file picker's channel and Linux portal, socks5_proxy's handshake, dart:ui's codec, the proxy rule, the Tor runtime, the app's cache and data directories | `on FileDialogFailure`, `on SocksHandshakeFailure` (an `IOException`), `on EngineImageFailure`, `on ProxyRefused`, `on TorRuntimeFailure`; a `FileStore` fails with `IOException` only |
| `HostBrowser` (`services/host_user_agent.dart`) | the user agent a site sends when the user set none (UAID-005) | `webViewUserAgent(override)` at both native settings writers; `sentUserAgent()` for the requests made for a site (`SiteUserAgentClient`) |
| `ArbMessages` (`l10n/runtime/arb_messages.dart`) | the active locale's messages, read from its ARB asset at run time | `AppLocalizations.of(context).key`, generated by `tool/gen_l10n.dart` |
| `Guarded<T>` / `SiteEventInbox` (Kotlin) | native state shared with IO threads | reachable only inside `with { }` |
| `ActivationStep` (`services/activation_step.dart`) | the steps of an activation, a memory-pressure plan and an unload as `formal/activation.tla` names them, their outcomes and the platform calls each may wait on; a flow's steps are a `StepTable` (`ActivationTable.activationFlow`, nesting `SiteUnloadEngine.unloadFlow` and the jar's; `TabTable.tabInputs` and `tabFlow` for a tab's; `BackgroundWakeEngine.table` for a wake's; `ArchiveController.closeTable`, `SiteDeletion.deleteTable` for an archive close's), which marks them | `ActivationSteps.mark(step, outcome:, site:)` for an input; a `Step` of a table otherwise |
| `FlowInput` / `Await` / `When` / `Ends` (`services/step_flow.dart`) | a flow written in the order it runs, compiled to a table's steps: each arm goes on to the await that follows it, and a decision over a reply is plain Dart run per value as the flow is built, so it cannot reach the shared state | `FlowInput(step, at: place, decide: Ends(..., next: Await(step, at: place, ...)))`; its `steps` answer the table's places (`ActivationTable._spaceFlow`) |
| `ActivationWorld` / `Witness` / `Mutant` / `HandMistake` (`test/formal_model/checks.dart`), `printWorlds` / `EnvAction` (`test/formal_model/worlds.dart`) | every check of `activation.tla`: a world's constants and the invariants that hold there, a behavior it must reach, a planted mistake and the invariant it breaks in each world it is caught in, so a mistake that names no check does not compile; and a world printed for every two actions that meet where no written world gives both their needs | one enum value per check; `models.dart` prints a config each, the printed worlds' too, and `checks.tsv`, which `check.sh` runs |
| `Planted` (`services/step_table.dart`), `planted` (`test/formal_model/mutants.dart`) | a mutant of the model run as code: the tables and definitions the runner takes in place of the code's while a test runs, so the schedules must catch what TLC catches | `planted(m).run(() => ...)`; `test/planted_mistakes_test.dart` names the script each breaks, or owes why none reaches it |
| Startup witnesses (`NativeIntercept`, `DnsLoaded`, `BlockerLoaded`, `CdnLoaded`, `TrustedHostsLoaded`) | that a service's load has run: only its `initialize()` makes one, and it carries what the load made (the service itself; for `NativeIntercept`, the sends), so startup work that needs the load is a method on it; main() starts every load at once and reads the rest after they all end | `WebInterceptNative.initialize()`; `dns.mirrorInto(native)`, `blocker.seedHostsInto(dns)` |
| `Reached<P>` / `LaunchPhase` (`controllers/startup_controller.dart`) | the page's launch as facts that are types: a call that needs one takes its proof, which only the restore makes, and a later phase extends those it implies, so the order is the compiler's | `refreshPinned(after: Reached<SitesOnPage>)`, `handleWarmLaunch(after: Reached<Launched>)`; `StartupController.launched()` |
| `DesktopWindow` (`services/desktop_window.dart`) | whether a close of the desktop window only hides it, as the runners are told it, and the window brought back (NOTIF-018) | `DesktopWindow.instance.start()`, `.show()`, `.quit()`; the runners' `desktop_window` channel (`linux/my_application.cc`, `macos/Runner/MainFlutterWindow.swift`) |
| `DesktopTray` (`controllers/desktop_tray.dart`), `TrayMenus` (`services/tray_menu_engine.dart`) | the icon in the desktop's status area while a close only hides the window (on macOS, while the `desktopTray` experiment is on too), and what its menu holds: the window, each site with notifications on and its title's unread count, quitting, each line keeping its id while the app runs (NOTIF-019) | a `TrayIcon` (`services/tray_icon.dart`): `StatusNotifierTray` on Linux (StatusNotifierItem and dbusmenu on the session bus), `MenuBarTray` on macOS (the runner's `tray` channel); a press is a sealed `TrayAction`; a site opens through `BackgroundSitesController`'s notification-tap path |
| `LaunchTimeline` (`services/launch_timeline.dart`) | when this launch reached each `LaunchMark`, from main(), written as one App logs line when it ends (DEVTOOLS-013) | `LaunchTimeline.reached(LaunchMark.x)`; `end()` once |
| `ProcessRoute` (`services/process_route.dart`) | the process-wide proxy rule where one covers every webview (Android outside router mode): the route in force and what runs on it (a site's webview, a nested screen, a wake's check); every write a claim taken in turn, asserting nothing else running needs another route (PROXY-008) | `ProxyManager().setProxySettings(settings, siteId:, occupant:)`; `ProcessRoute.instance.release(occupant)` |
| `OutboundProxy` (`services/outbound_http_types.dart`) | the proxy a connection opened on a site's behalf goes through (a favicon, a title, a user script, a download, the webview), its Tor isolation tag stamped in (BUG-030) | `model.outboundProxy`, made only by `OutboundProxy.ofSite(stored, site:)`, or by name for the app's (`OutboundProxy.app`, `.ofApp(settings)`); every outbound API's required `proxy:`, `SitePosture.container.proxy`, `waitsForTor` and `testProxyConnection` take it, and `.resolved` is the one resolution rule, the only maker of the `ProxyRoute` every `OutboundHttpFactory.clientFor` takes, with a `BodyEncoding` (a download's is `asSent`); `webspace_lints`' `raw_http_client` refuses a client made in `lib/` outside an `OutboundHttpFactory` |
| `Isolation` (`services/isolation.dart`) | how the sites' cookies are kept apart, decided once by `Isolation.probe` in the restore: `Containers` holds the container engine and cookie manager, `SharedJar` the legacy engine, so each is in hand only where it exists; a site's bound container is resolved from it into its posture | `switch (_sites.isolation)`; `isolation.cookiesAt` / `deleteCookie`; `SitePosture.container.containerId`; `useContainers` derives from it |
| `WebViewTabBinding` (`services/webview_tab_binding.dart`) | which tab's history a site's one webview shows: the tab it was built for, and the back stack queued for the next build, tagged with the tab it was read for (TAB-003, BUG-036) | `model.tabBinding.queue(bytes, tab:)`; the build's `bind` / `take(tab:)`; `captureNavigationState()` returns a `CapturedNavState` |
| `PagePhases` (`services/page_phase.dart`) | one webview's life as its callbacks report it: which callbacks may act, what a load needs before it starts (`PagePrerequisite`), and which document a script decided across an await lands in (`PageScope`, US-007) | `phases.on(PageEvent.x, view: controller.platform)` at the top of each callback (the plugin passes a new wrapper per callback; the platform controller is the view); `phases.asks(mainFrame:)` in `shouldOverrideUrlLoading`; `phases.page(controller).evaluate(js)` |
| `SiteId` (`settings/site_ids.dart`), the names made from it (`ContainerKey` and its native `ContainerName`, `ws-<key>`; `RouterIdentity`; `TorTag`), `TabId` (`services/site_tab.dart`), `WebspaceId` (`webspace_model.dart`), `UserScriptId` (`settings/user_script.dart`), `FilterListId` (`settings/filter_list_id.dart`), `ShortcutId` (`settings/shortcut_id.dart`), `RpId` (`services/passkey_engine.dart`), `DownloadTaskId` (`services/download_manager.dart`), and the proxy library's `GatewayId`, `CredentialsId`, `SavedProxyId` (`settings/proxy_ids.dart`) | a site's identity, each name it goes by outside the app (its container, an archive-tier site's opaque; its proxy-router credential; its Tor circuit), a tab's within its site, a webspace's, a user script's, a filter list's, an Android home screen tile's, a passkey's relying party, only as checked against its origin, a download's, which a page hands back, and each proxy library entry's; a reference to an entry is a sealed `LibraryEntry` whose case carries its kind's id | `X.parse` where one comes in (JSON, a channel, a file name), `X.mint()` for a new one; `model.containerKey`, `RouterIdentity.ofSite`, `TorTag.ofSite` |

Layers: UI `screens`, `widgets`, `controllers`, `theme`, `main.dart`, `app.dart` · model `web_view_model.dart`, `demo_data.dart`, `diag_seed.dart` · services `services` · values `settings`, `utils`, `webspace_model.dart` · platform `platform`.

Debt, files importing upward (the gate's list, target 0): services → model (engines take `WebViewModel`; each needs a narrow interface).

| Axis | Budget | Now | Funnel |
|---|---|---|---|
| per-site field | 3 | ~7 edits, 4 files; a save, a read or a QR decision left out fails to compile | `SiteField` + `SitePosture` group; debt: the model's constructor |
| pref | 2 | 2 | `AppPref` |
| capture kind | ~5 files | ~5 files | `CaptureKind` |
| settings row | 1–3 lines | 1–3 | `SettingTile` / `ChoiceTile` |
| page script | 3 | 3 (the file, a `PageJs` value, a sample in `test/js/helpers/page_js_samples.js`) | `PageJs` |
| release | 3 | 3 (version, changelog, fixtures) | the `pubspec.yaml` version line; the changelog and fixture gates key off it ([docs/releasing.md](docs/releasing.md)) |
| secret store | 2 | 6 ("Adding a new credential / secret" below) | `SecureJsonStore` + `OrphanStore`; debt: hydration, post-import notice, export test by hand |
| await step in an engine | 1 (a `Step`) | 2 (the `Step`, its `ActivationStep`); the model's action and its proof case are printed, an input's own step (`Step.input`) included. Debt: the environment's actions (`Move`, `Login`, `ClearJar`, `ViewBuilt`, `ViewGone`, `Frame`) are hand-written in `activation.tla`; the DNS lists' prune, import and startup load write them outside `DnsBlockService.table`, and a headless check's attach takes no part in `ViewBlockers`; the plan's picks by the loaded-site cap and its cache clears are printed as any choice of evictable sites of the size the caps leave, so the code's recency order is one the model checks, not one it knows; a tab input on a site off screen (an activation inside the tab gate) and a reroute asked while the tab gate is held are listed in `steps_uncovered.tsv`, and a reroute that flips more than one site's link tabs, or tabs another site opened, writes in `Unmodeled.identityChange` | `StepTable`, the model and its proof cases printed from it |
| flow in the model | its own checks and one per flow it shares a variable with | every activation-side flow in one `Next` of `activation.tla` | footprints ([formal/README.md](formal/README.md#composition-by-footprint)) |

Flag for review before changing: persisted formats, the Dart to page-script bridge, any join above.

Health, monthly: `node tool/architecture_health.js` prints files per fix commit, gates, `catch (_)`, asserts per 1k lines, comment share, `String` ids, hand-kept `toJson`/`fromJson` classes and layer violations, each with the direction it should move.

## Style (output, code, commits)

- No preamble, no closing fluff, no em-dashes, no emoji.
- **End a long answer with a TL;DR.** Long is roughly more than a screen, or
  more than two sections. It is the one closing section that is not fluff, so
  it carries facts a reader can act on (what changed, what it means, what is
  still open), never a recap of the headings above it. Short answers get none.
- Don't use the phrase "load-bearing".
- **A PR body or a long answer is structured, not prose.** No paragraph over two lines
  without a list, a table or a heading carrying it; a reviewer scans before reading.
- **A run is green when its exit status says so.** The last visible test passing is not;
  read the exit line before reporting a suite, a gate or a verify as passing.
- Code first; explain only the non-obvious.
- Default to **no code comments**. Only add when the *why* is non-obvious (hidden constraint, workaround for a specific bug, surprising behavior). Never restate what the code does. Never reference the current task or PR.
- Commit messages: short subject (<70 chars, imperative), 1-2 line body for the *why* if needed. No marketing prose, no bullet lists of every changed file, no "this commit also...".
- Don't speculate. Read the code or docs before asserting an API/version/flag.
- **An implementation file stays under 2000 lines.** Past that it is split by
  concern: what stands alone (a controller, a widget, a top-level function, a
  class and the enum only it uses) moves to its own file; what exists only for
  one owner (a private enum, a small extension) stays beside it. A file kept
  longer is a monolith that reads best whole, such as a backtracking search,
  and is named with its reason in
  [test/js/file_size.test.js](test/js/file_size.test.js). Test files may be as
  long as their cases.
- **JavaScript the app runs in a page is a file in `lib/js/`**, read through
  `PageJs` ([lib/services/page_js.dart](lib/services/page_js.dart)). A value
  reaches it only through `withConfig`, as JSON, never by building the
  script's text. A one-line expression that calls into an installed script
  (`__wsStopRealCapture()`) may stay inline. Gate:
  [test/js/page_js.test.js](test/js/page_js.test.js) (rung 5: no type says a
  Dart string is not JavaScript); every script also passes ESLint as injected
  ([test/js/page_js_lint.test.js](test/js/page_js_lint.test.js)).
- **No catch-alls.** Catch the types the call is known to throw, read from the
  callee's source (`on SocketException`, `on PlatformException`,
  `test: (e) => e is SocksClientException`), never `catch (_)`, `on Exception`,
  `on Object` or `onError: (_) {}`: those also take what nobody expected (an `Error`
  is a bug) and leave nothing to fail the test that would have caught it. A family
  the callee's library declares (`IOException`) names its failures; `Exception`
  names none. When a failure already has an owner (a future dart:io observes, a
  request that reports it), don't add a second listener to silence it; restructure
  so there is one. A value cast from JSON or a channel is read by a pattern, so a
  wrong type reads as absent instead of throwing a `TypeError` a catch would have
  to swallow. A parser of web content that rejects input with errors names them
  once, at its owner (`loadUntrustedSvg`). `avoid_catches_without_on_clauses` is an
  error in `analysis_options.yaml` and CI's `validate` job fails on analyzer errors,
  so a bare `catch` does not land; which type a clause names is read by
  `webspace_lints`' `catch_all` rule, which fails on a generic `on`, `test:` or
  `onError<E>`, an error handler that never reads its error, a `catchError` or
  `handleError` without `test:`, and a plain `Exception(...)`. A catch-all kept
  on purpose is an `// ignore: webspace_lints/catch_all` listed with its reason
  in [test/js/lint_ignores.test.js](test/js/lint_ignores.test.js), which holds
  every ignore of the plugin's rules to a list that only shrinks.
- **A future nobody awaits says so:** `unawaited(f())`. `unawaited_futures` and
  `discarded_futures` are errors too, so a dropped `await` (a test's missing
  `await tester.pump()` among them) fails the analyzer.

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

## Releasing

"Prepare the release" means one PR that bumps `version:` in `pubspec.yaml`
(the maintainer picks which part moves; ask), adds the changelog for the new
build number and commits the backup compat fixtures for the new version, then
is squash-merged and its commit tagged. Steps and the gates that catch a
missing piece: [docs/releasing.md](docs/releasing.md).

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
- **A change under `formal/`, to a step table or to the printer is pushed only after
  `./formal/verify.sh` passes locally.** CI runs it too, an hour later; a red push costs
  everyone that hour.
- **A long branch is re-cut into theme commits before review**, each one thing a reviewer
  reads whole (walks and schedules; the model and its replay; tables and the printer; a bug
  each), authors kept, translations still their own commit.
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
- **No link to a Claude session** in a commit message, a PR body or a comment (a `Claude-Session:` trailer, a `claude.ai/code/session_…` URL): it opens only for the account that ran the session, so it tells a reader nothing. The same gate fails a commit carrying one, and a PR body as it reads when the job runs; a comment has no gate (rung 6: no check sees one before it posts). A GitHub tool that appends its own footer to a PR it opens may link the session there: edit the body after opening, and re-run the job.
- **No language model provider is signed on a commit.** A commit written with an assistant carries no `Co-Authored-By:` (or any other trailer) with the model provider's address (`noreply@anthropic.com`, `openai.com`): the person who commits is the author. This overrides any tool's default attribution. Same gate.
- After a rebase across a commit that touched `lib/l10n/*.arb`, run `fvm dart tool/gen_l10n.dart` before trusting the test run: `lib/l10n/gen/` is gitignored, so a stale copy fails to compile against the new keys and the failures look like the rebase broke something.

- **`[ci-only: <jobs>]` narrows a CI run.** A commit message carrying it runs only
  the jobs it names and skips the rest; tokens are `validate`, `design`, `android`,
  `linux`, `apple`, `screenshots`, comma-separated (`[ci-only: apple,validate]`).
  `screenshots` runs the store screenshot jobs on any PR, as a manual run's
  `screenshots_only` input does. For a bisection
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
# fvm — required (.fvmrc pins the Flutter version)
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

# PipeWire, WirePlumber and GStreamer: only to run
# test/linux/screen_share/check.sh, which skips without them (fails with CI=true).
sudo apt-get install -y pipewire pipewire-bin wireplumber dbus-daemon jq \
  gstreamer1.0-pipewire gstreamer1.0-tools gstreamer1.0-plugins-base libpipewire-0.3-dev

# elan: only to run formal/verify.sh's Lean check (formal/lean/). Skip it if
# `command -v lake` already prints a path. With no default toolchain,
# formal/lean/lean-toolchain alone picks the Lean release, as .fvmrc picks
# Flutter's. Without lake the step skips locally and fails with CI=true.
curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
export PATH="$HOME/.elan/bin:$PATH"
```

## Commands

Prefix all Flutter/Dart with `fvm`.

```bash
fvm flutter pub get
fvm dart tool/gen_l10n.dart                              # l10n API; native builds run it, test/analyze/web don't
fvm flutter test                                         # all Dart tests
fvm flutter test test/cookie_isolation_test.dart         # single file
npm run test:js                                          # JS shim tests (jsdom)
./scripts/test_all.sh                                    # Dart + JS
WS_PERF=1 fvm flutter test test/perf/                    # benchmarks (test/perf/README.md)
fvm dart analyze --no-fatal-warnings                     # errors fail; flutter analyze drops the plugin's
(cd tool/webspace_lints && fvm dart pub get && fvm dart test)   # the analyzer plugin's own tests
fvm flutter build apk    --flavor fdroid --release       # F-Droid (CI, unsigned)
fvm flutter build apk    --flavor fmain  --release --split-per-abi   # Play (signed)
fvm flutter build ipa    --release                       # iOS unsigned
fvm flutter build macos  --release                       # unsigned; see below
./scripts/sign_macos.sh devid                            # notarized zip + dmg (needs certs)
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

**Main** — [lib/main.dart](lib/main.dart) runs the startup steps and `runApp`; [lib/app.dart](lib/app.dart) is `WebSpaceApp` (root MaterialApp); [lib/screens/webspace_page.dart](lib/screens/webspace_page.dart) is `WebSpacePage`, whose state holds one `SiteRuntime` `_sites` ([site_runtime.dart](lib/controllers/site_runtime.dart): the models, the loaded sites and the one on screen, webspaces) and the controllers in [lib/controllers/](lib/controllers/) (startup, activation, shortcuts, archives, backup, webspaces, site editing, site resets, full screen, back gesture, surface repaint, background sites, app lifecycle, site network, tabs, links). Their dialogs are `Dialog*Prompts` in [lib/widgets/](lib/widgets/). A controller talks back through its typed `*Host` interface, implemented by `_PageHost` at the bottom of webspace_page.dart; `lib/services` never imports a controller.

**Site-set changes** — every add, delete, move, edit, import, archive open/close goes through `SiteSetCommit.commit(SiteSetChange)` ([site_set_commit.dart](lib/controllers/site_set_commit.dart), [site_set_change.dart](lib/controllers/site_set_change.dart)). The sealed change's `effects` record (every field required) decides what follows it, and the funnel runs those steps in one fixed order, so a new kind of change does not compile until it answers each one.

**Services** ([lib/services/](lib/services/)) — `cookie_secure_storage`, `html_import_storage` (AES, a file import's only copy), `icon_service`, `dns_block_service`, `webview` (CookieManager wrapper, WebViewTheme).

**Cookie isolation — two engines, runtime-selected.** The restore decides once (`Isolation.probe`, [isolation.dart](lib/services/isolation.dart)) and sets `SiteRuntime.isolation`: `Containers` holds the container engine and cookie manager, `SharedJar` the legacy engine, so code that needs either takes it from a `switch` on the witness.

- **Container engine** ([container_isolation_engine.dart](lib/services/container_isolation_engine.dart)) — Android System WebView reporting `MULTI_PROFILE` (runtime-detected, no published milestone version), iOS 17+, macOS 14+, Linux WPE WebKit 2.40+. Each `siteId` → native container `ws-<siteId>` (`androidx.webkit.Profile` / `WKWebsiteDataStore(forIdentifier:)` / `WebKitNetworkSession` cached under `<XDG_DATA_HOME>/flutter_inappwebview/containers/`) owning its cookies, localStorage, IDB, ServiceWorkers, HTTP cache. Same-base-domain sites load concurrently — no conflict-unload, no capture-nuke-restore. Bridge: [`ContainerNative`](lib/services/container_native.dart). Lifecycle ops route through fork's `inapp.ContainerController`; only the Android `MULTI_PROFILE` feature gate lives in [`WebSpaceContainerPlugin.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebSpaceContainerPlugin.kt). Bind happens in `InAppWebView.prepare()` / `preWKWebViewConfiguration` / Linux `webkit_web_view_set_property("network-session", ...)`, driven by stock `inapp.InAppWebViewSettings.containerId` set by `WebViewFactory.createWebView`. Spec: [openspec/specs/per-site-containers/spec.md](openspec/specs/per-site-containers/spec.md).
- **Legacy engine** ([cookie_isolation.dart](lib/services/cookie_isolation.dart)) — Windows, web, anywhere `ContainerController.isClassSupported` is false. Sites with matching base domains can't load simultaneously; switching unloads the conflict and runs capture-nuke-restore on the shared cookie jar. Spec: [openspec/specs/per-site-cookie-isolation/spec.md](openspec/specs/per-site-cookie-isolation/spec.md).

**Other patterns** — Lazy webview loading (`SiteRuntime.loaded`); `isDemoMode` flag (no persistence, seeded data).

**flutter_inappwebview fork** — adds containers + per-site iOS/macOS proxy. Monorepo: <https://github.com/theoden8/flutter_inappwebview>. `dependency_overrides` in [pubspec.yaml](pubspec.yaml) pin every platform plugin to one git ref. Pub caches under `~/.pub-cache/git/`. Currently a mutable branch — tag it before each release. Surface area: `grep -rn '\[WebSpace fork patch\]' ~/.pub-cache/git/flutter_inappwebview-*/`.

**Persistence** — SharedPreferences for sites/webspaces/theme; cookies in flutter_secure_storage by `siteId`.

## Tests

Dart in `test/`, integration in `integration_test/` (screenshots).

Random walks ([test/helpers/walk/](test/helpers/walk/)) drive the real engines with seeded action sequences landing between platform replies, as events do, plus noise that must change nothing it does not predict; each runs twice and must match itself, and a broken one shrinks to a list that pastes as a regression. CI runs fixed seeds; `WALK_SEED=n` reruns one, `WALK_SEEDS=k` explores. Within a bound the same world is enumerated whole: every schedule of replies and arrivals with at most two preemptions ([schedules.dart](test/helpers/walk/schedules.dart)), less those that only move a flow's own reply ahead of steps whose footprints share no variable with it (sleep sets; held to the full search on sample worlds, `SCHEDULE_REDUCTION=off` runs it), with each bug found kept as a named script ([activation_schedules_test.dart](test/activation_schedules_test.dart)). A change to state other features read adds its actions and invariants to a world there ([site_activation_walk_test.dart](test/site_activation_walk_test.dart)).

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

- A bug fixed once at the code that owns it, or a flake in one test's fixture, is not
  recurring: its gist, and any limit the fix leaves, goes in the doc comment of the test
  that pins it, and the spec names that test. A file here is for a class.
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
- **`./formal/verify.sh` runs all of it** (`--fast`: the printed modules and `activation.tla`
  only), and CI's `validate` job runs nothing else for `formal/`.
- **Adding a spec that touches shared state → run the mix gate:** add its actions to `Next`
  and its property to the `.cfg`, then `./formal/verify.sh`. A counterexample means it does
  not mix; the trace names the breaking interleaving. Fix the design, not the model.
- Standalone models (no shared kernel state) live beside the kernel: `archive.tla`
  (ARCH-001 byte-identity, a 2-safety hyperproperty via self-composition), `renderer.tla`
  (BUG-002 dead-renderer recovery), `proxy.tla` (mismatched-proxy mutual exclusion),
  `kiosk.tla` (KIOSK-001/002/003 locked-shell sealing), `activation.tla` (a switch split
  at its awaits, with memory pressure, row moves and the jar's turns between them).
- Each model carries **negative** demonstrators (a mutation that MUST be caught) and
  **positive** reachability witnesses (a legal behavior that MUST be reachable) — run by
  `./formal/check.sh`, which `verify.sh` calls. `trace/` validates real `LogService` traces against the kernel's
  observable projection (the model↔code bridge).
- `formal/proofs/` holds **unbounded TLAPS proofs** (machine-checked by `tlapm`): every
  kernel safety invariant *and* the surface-repaint liveness `RepaintLiveness` for all N,
  not just TLC's N = 3. Run via `proofs/check_proofs.sh`.
- `formal/lean/` (Lean 4, no Mathlib) proves when a check may be split, over any action well
  formed over its footprint: `commute`, `frame_preserves`, `cone` (an invariant holds iff it
  holds where only its cone runs) and `pairwise_unsound` (the footprint gate's pairs are
  coverage, not soundness); over the printed `lean/Footprints.lean` it decides that every
  invariant is checked in a world taking its whole cone. Never a build dependency: only
  `verify.sh`'s LEAN step and CI's `validate` job use it. [formal/README.md](formal/README.md#what-a-footprint-licenses).
- **An engine written as a step table is its own model.** A guard of a
  [`StepTable`](lib/services/step_table.dart) is one tree that runs and prints; its leaves are
  the model's variables, each declared once with how the engine reads it (`Var`) and takes a
  new value (`Mutable`, `Indexed`; `.remote` where only a platform call reaches it), its sets
  known by membership (`Members`), quantified and filtered over a `Bound` (`forAll`, `where`),
  and the model's operators: a `Def` in the engine that owns its variables, run there and
  printed (`activation_ops`), or called by name (`Expr.op`) elsewhere. A write is a `Write`
  the runner applies (`Act.of`); what a call reads as it starts, for a write its reply
  makes, the flow records as the call is issued (`Call.reads`, printed on the arm that enters
  the place); a ghost the model keeps for an invariant is an assert in
  the code (`ghost`); and after every step the runner asserts the frame the model prints as
  `UNCHANGED`: a step changed only the variables its arm declares (`vars:`). The walks hold
  that frame over every variable the code holds, not only the ones a table reads: each
  stretch of code between two awaits is compared before and after and charged to its flow's
  next mark, so a table that declares less than its code writes fails a schedule
  (`FrameMistake`, planted in `activation_schedules_test.dart`). A field takes
  only its own type, and a table answers every place in an exhaustive `switch`.
  [test/formal_model/main.dart](test/formal_model/main.dart), run by the test runner,
  prints the tables' actions for `activation.tla` to extend
  (`SiteUnloadEngine.unloadFlow`, with `CookieIsolationEngine`'s tables nested at the jar's
  places), their TLAPS cases (`activation_tables_proof`, which `proofs/activation_turns.tla`
  takes whole), and every engine's declared model as `models.json`; a new
  engine's model is one entry in [models.dart](test/formal_model/models.dart). Change the table, not the model;
  a mistake in a table or a definition is a mutant there, a copy with the fault. The printed
  modules are derivatives, written under `build/formal/`.
- **What a step table holds to**, each line a mistake the replay or TLC caught once:
  - **A step is one await.** A call that awaits twice (a capture: the webview's reply, then the
    file write) is two steps, since a check between its awaits is invisible to a one-step model;
    the walks fail a step that waited on several calls unless it names why that is safe
    (`ActivationStep.severalAwaits`: the page's pauses, which write nothing the model holds).
    A caller outside any table runs the same pieces in sequence (`captureStateBytes` over
    `NavCapture`), never a second copy of the sequence.
  - **A call reads at its start, the model writes at its reply.** What the write needs of the
    state at the start is a flow field recorded as the call is issued (`Call.reads`), never an
    expression over the reply's state.
  - **A field a call receives reads as the reply within its step**, not as its value before.
  - **An arm's effects read the state the step found**, so an effect over what another effect
    of the same arm writes is given it (`TabVars.framed(site, loaded:)`: a preload's commit
    loads the site its frame binds). Within one `Act.of` the runner reads every write's value
    before any lands, as TLA+ reads a primed write's.
  - **A variable the model keeps for a subset** (`Tabbed`) is read under that membership in every
    guard, so an unfollowed site takes the outcome the code takes.
  - **A step whose arms pick marks the pick** (`tab:`): two picks sharing one label make the model
    ambiguous and the replay stalls there.
  - **A call the platform can refuse has its refusal as an arm** (`Refused`, with the failure's
    type as a `Refusal`): the model's alternative to the reply where a world lets it, never a
    catch beside the table, which the model cannot see (ISO-014).
  - **A mutant is the bug's shape**, one fact moved and the other left (the key at the reply,
    the bytes from the start); a mutant TLC accepts is a consistent design alternative, not a
    planted mistake, and says nothing.
  - **TLC passing proves the model; only the replay proves it is the code's.** A change to a
    table, a definition or the printer is not done until `check_steps.sh` passes.
  - **A planted mistake is its own `Mutant`**, its tables a definition in `mutants.dart`,
    never a flag on the production definition it mutates.
  - **A check is stated apart from what it checks.** An assert or invariant that reads the
    guard's own definition weakens with it, and a mutant of that definition goes uncaught
    (`Inv_OneRoute` reads the proxy and Tor rules, not `RouteFree`).
  - **A new step on a hot flow is measured.** It multiplies the interleavings: name the base
    config's `Finished in` before and after in the PR (the two-step capture doubled it).
- `trace/check_steps.sh` replays every step the code marks (`ActivationStep`) in every schedule
  `test/activation_schedules_test.dart` runs, as a step of `activation.tla` ending in the state the
  code was in; the model's `Outcomes` is printed from the enum, the walk fails on a platform call
  no step declares, and each branch is taken or listed in `trace/steps_uncovered.tsv`. A new await
  in those engines is a new `Step` of its table, which prints its action; the replay holds the
  hand-written inputs and the tables' leaves to the code.
- A bug's recurrence is also gated in **code**: structural Node tests under `test/js/`
  (`surface_repaint_funnel`, `renderer_gone_recovery`) fail CI if a new path skips the fix.
- Don't commit `tla2tools.jar`, `states/`, `.tlacache/`, generated `mc_*.tla`, or anything
  under `build/formal/` (derivatives).
- Full method + the new-spec workflow: [formal/README.md](formal/README.md).

## OpenSpec features

Specs live under `openspec/specs/<slug>/spec.md` (Given/When/Then). **Read the relevant spec before modifying a feature.** **Every requirement is named by the check that verifies it** (its id in a test's name, a model's action or an assert's message), or listed in [openspec/unverified.tsv](openspec/unverified.tsv) with why not yet; [test/js/spec_verification.test.js](test/js/spec_verification.test.js) fails on neither, on a listed one a check now names, and on an id two requirements share. `node tool/spec_map.js` prints which checks name each requirement, strongest first. A slug marked *(change)* is still in flight: its requirements live at `openspec/changes/<change>/specs/<slug>/spec.md`, where the change is not always named after the capability (`tor-proxy` sits in `add-ios-tor-proxy`) and more than one change can hold a slice of it, so grep the requirement id when the obvious path is absent. Slugs:

| Slug | One-liner (when not obvious) |
|------|------|
| accessibility | which of Apple's nine accessibility labels the app may claim per device (all No today, with what blocks each); Android's bar instead (core app quality touch targets, contrast, descriptions; the Play pre-launch report every release); which OS settings reach the chrome and web content on every platform; shims pass the engine's own accessibility media features through |
| always-open-home | per-site: navigation URL reverts to `initUrl` on cold start and shortcut tap, cookies and other stored state survive; site switches and a transient background are not resets |
| captcha-support | |
| clearurls | tracking-param removal, per-site toggle |
| legal | App Store encryption declaration + licence composition of the shipped work |
| configurable-suggested-sites | the user's own list, empty in every build so no flavor changes the Dart; a downloaded, filtered CrUX top list completes a typed address on the device |
| content-blocker | ABP filter lists via adblock-rust (network, cosmetic, procedural, $redirect/$csp/$removeparam); per-site list selection is a mask over the app-wide set |
| cookie-secure-storage | encrypted cookie persistence |
| design-gallery | designer works in Dart on web; web-clean, token-validity, render-matrix and card gates |
| desktop-mode | per-site UA → JS shim (userAgentData, maxTouchPoints, viewport rewrite) |
| developer-tools | JS console, cookie inspector, HTML export, app logs; in developer mode a background log that outlives the process (native refresh steps, wakes, unloaded notification sites, OS gates) with site names kept in memory only |
| dns-blocklist | Hagezi list, severity levels, per-site toggle; per-site level is a mask over the app level (the levels do not nest, so each domain carries a bit per level) |
| downloads | http/https/data/blob, streamed progress + save dialog |
| external-scheme-handling | intent:// auto-resolves to http(s) fallback (silent route); prompt only when no web equivalent |
| file-import-sites | local HTML via HtmlImportStorage |
| fullscreen-mode | hide app bar/tab strip/system UI; per-site auto |
| home-shortcut | Android pinned shortcuts; iOS/macOS expose an "Open Site" App Intent through Shortcuts instead (no pin API) |
| http-auth-prompt | a server's or proxy's 401/407 challenge as a per-site sign-in dialog; only the site's own hosts may ask, the credential is remembered in secure storage per site, never exported, and archive-tier sites keep none |
| https-upgrade *(change)* | plain-http main-frame navigations retried over https, silent per-host fallback; default-on knob, forced on by Tracking Protection |
| inactive-tabs *(change)* | tabs inside a site, on by default per site and off for a kiosk site; requirements (TAB-*) at `openspec/changes/inactive-tabs/` |
| icon-fetching | a site's icon from the site only, never a third-party icon service. The page's own icon wins when it is on the site's host, >= 32px, and not a badge swapped in after load: on Android, and on Linux from WPE 2.54, the one the webview reports (`onReceivedIcon`); elsewhere the links the page declared, fetched through the site's proxy and blockers. Else the home page's markup or `/favicon.ico`; developer mode can reset every icon cache |
| incognito-mode | per-site: nothing the site stores survives an app restart (cookies, localStorage, IDB, SW, cache, last URL/title); typed configuration does |
| ios-universal-link-bypass | cancel+reissue gesture http(s) navs to dodge AASA |
| ip-leakage | proxy coverage contract; fail-closed on SOCKS5; WebRTC + DNS |
| js-shim-tests | jsdom + node:test, with Dart drift check |
| kiosk-mode | per-site toggle; shortcut launch opens chrome-less (no drawer/tab strip/menus/settings), plain app launch restores access; no passphrase |
| language | Accept-Language + DOCUMENT_START navigator.language/Intl |
| localization | UI strings in ARB, read from the assets at run time (only the typed API is generated); no-unkeyed-text guard; coverage parity tests |
| integration-tests | flutter `integration_test/` harness conventions + headless Linux CI setup |
| lazy-webview-loading | on-demand creation, IndexedStack placeholders |
| link-intent-routing *(change)* | which site, tab or app an outbound link opens in. Published specs cite LIR-* ids, but the requirements are still split across `openspec/changes/{route-outbound-via-lir,default-app-for-links,web-search}/specs/link-intent-routing/` |
| localcdn | cache CDN resources locally (Android) |
| navigation | back gesture, drawer swipe, refresh, race guards; URL-bar site info sheet (site + container); desktop keyboard shortcuts |
| nested-url-blocking | nested InAppBrowser; gesture-less cross-domain hops blocked on every site (no switch); per-site external link mode (in app / browser / block), routing to other sites only in app |
| page-zoom | per-site zoom; viewport meta on mobile (Android pins the layout width), CSS `zoom` on desktop |
| passkey-support | every site outside an archive. Android: the shim hands `publicKey` requests to Dart, which asserts the calling frame's origin to Credential Manager (`CREDENTIAL_MANAGER_SET_ORIGIN`, a normal permission) with its own clientDataJSON hash; each provider decides whether to trust the app with an origin. Emulator gate: `scripts/run_android_passkey_tests.sh`. iOS/macOS: no bridge, WebKit's own WebAuthn, which needs Apple's browser passkey entitlement; an archive-tier site gets a block shim that hides it |
| per-site-cookie-isolation | legacy engine (fallback) |
| per-site-containers | native containers (preferred when supported) |
| per-site-location | geo + IANA tz override + WebRTC lockdown |
| platform-support | platform abstraction layer |
| proxy | per-site HTTP/HTTPS/SOCKS5; a proxy library (saved proxies, gateways, credentials tied to gateways) any site or the app-wide proxy picks from, with a connection indicator *(saved-proxies change)*; Android routes mismatched-proxy sites through a loopback relay where its WebView reports `MULTI_PROFILE` (PROXY-013) and serialises them elsewhere (PROXY-008) |
| proxy-password-secure-storage | secrets in flutter_secure_storage; never in JSON |
| screenshots | integration-test driven |
| screenshot-block | app-wide or per-site `FLAG_SECURE` (per-site applies while that site is on screen); Android only, switches absent where no public API blocks capture |
| app-settings | App Settings as an index: Appearance, Behaviour, Network, Privacy, User scripts, Backup and archives, Developer; each row a screen of its own with a summary of its state (BEHAV-002 rule); one tap, one action on every opener |
| settings-backup | JSON import/export; every released format still imports (per-release fixture corpus), and an import is planned whole before it is applied |
| settings-hints | where a settings row's text goes: state in the subtitle, explanation behind the hint button; fixed-string subtitles capped across all locales |
| site-behaviour | per-site Behaviour screen: how the app hosts the site (opening + display, link handling), reached from one row under "Site" |
| site-network | per-site Network screen: proxy, Tor exit, WebRTC policy, saved sign-ins, reached from one row under "Site" that names the route the traffic takes |
| site-editing | URL + custom name |
| site-permission-badges | drawer badges for location/camera/mic/background-audio grants; real device access vs simulated |
| site-settings-qr | share a site's configuration as a QR / `webspace://qr/site/v1/` URL; never carries secrets, cookies, user scripts or imported HTML |
| tls-trust-prompt | system + user CA trust by default; prompt only when the OS rejects a cert, then pin (host, port, sha256) so Dart-side clients match the webview |
| tor-proxy *(change)* | embedded Tor on iOS + macOS (the macOS Runner compiles `ios/Runner/TorControllerPlugin.swift`), per-site SOCKS5 circuit isolation (never per destination), no developer-mode or experimental gate. The macOS build is the only tier that runs the real handshake, and its Tor pod is why the macOS floor is 11.0. The Tor (external) switch in App settings > Network, with developer mode on or off, points Android (Orbot, InviZible), Linux and macOS (tor, Arti) at a tor already running, with the same per-site SOCKS credentials; on macOS it stands in for the built-in tor while on, switched without a relaunch (TOR-025). On Linux and macOS that tor's control port, when named (socket path or host:port; SAFECOOKIE or a keystore password, never plain COOKIE), lists how it isolates sites differently from the built-in one and gives it New circuits and exit countries, put back when released (TOR-026) |
| tracking-protection | umbrella per-site ETP: forces ClearURLs/DNS/content blocker/LocalCDN + injects anti-fingerprinting shim (Canvas/WebGL/audio/fonts/screen/hardware/timing/clientrects) seeded by siteId; a site follows it into WebKit's Lockdown Mode on iOS 16+ and macOS 13+ unless it sets its own (ETP-032), a switch no other engine has |
| user-agent-identity | engine-consistent navigator identity for the per-site UA (vendor/productSub/oscpu/buildID/platform/userAgentData); complements desktop-mode |
| upstream-webview-defects *(change)* | defects found auditing the pinned flutter_inappwebview fork's upstream tracker: a declined `onCreateWindow` still navigating on iOS/macOS, UA client hints that half-spoof, the plugin's unmasked console wrappers, the real Linux WPE build floor |
| user-scripts | per-site JS injection w/ timing control |
| web-camera-access | per-site camera for camera-only getUserMedia (banking QR flows); `cameraMode` ask/real/virtual/block. Virtual serves a user-picked image/looped video via a canvas `captureStream` shim (no real camera, no OS prompt); real grant ensures Android CAMERA perm |
| web-microphone-access | per-site audio capture; `microphoneMode` ask/real/virtual/block. Real hands over the device mic under the MIC-014 containment contract (on-screen site only, ends on deactivation, badged, never archived); virtual loops a user-picked clip through WebAudio into a `MediaStreamAudioDestinationNode`. Audio+video requests are split in every mode, so the platform's combined CAMERA_AND_MICROPHONE resource never arises from a shimmed page |
| web-screen-sharing | per-site `getDisplayMedia`: `screenShareMode` ask/real/virtual/block. Real on Android (its capture prompt for every share, a `mediaProjection` foreground service), Linux (the desktop portal's ScreenCast, a PipeWire stream) and macOS 14+ (the `SCContentSharingPicker`), frames pulled over the bridge onto a canvas track, held only by the site on screen and ended when it leaves (SHARE-017); virtual serves a picked image/video as the shared surface; top-frame only, never an audio track |
| web-push-notifications | per-site `notificationsEnabled` toggle: JS Notification polyfill → flutter_local_notifications, auto-loads + skips per-instance pause for notif sites, any notif site, loaded or not, vetoes the app-background JS pause (NOTIF-011), iOS `beginBackgroundTask` grace + `BGAppRefreshTask` wake, Android mirrors via `WorkManager` periodic wake (no foreground service); a wake checks every notification site, live ones reloaded and the rest in a headless webview with the site's own posture (NOTIF-016), waits for the loads and posts for a site whose title unread count rose (NOTIF-013/014) |
| archive | passphrase-gated archived webspaces in a fixed slot pool; active state stays byte-identical when no archive is open |
| background-audio | per-site toggle: skips per-instance pause + app-background global JS pause (any-loaded veto), iOS `.playback` AVAudioSession + `audio` background mode; Android `mediaPlayback` foreground service + MediaStyle notification (BGAUDIO-006) driven by a page-JS media-session bridge; CI-tested via lifecycle injection + beaconing HTML fixture, plus a 3-tier notification gate (BGAUDIO-007: real-Chromium shim, channel contract, emulator assert on `getActiveNotifications()`) |
| block-statistics | persistent app-wide protection report: per-category daily buckets, 7/30-day ranges, all-time total in plaintext prefs; the itemised half (blocked hosts, per-site counts) in an AES blob keyed from the keychain; archive-tier sites excluded from both |
| web-extensions *(change)* | iOS 18.4+ and macOS 15.4+: browser extensions imported from a file (.crx, .xpi, .zip), switched on per site and limited to its domains, one `WKWebExtensionController` per site container, behind an Experimental switch; requirements (WEBEXT-*) at `openspec/changes/webkit-web-extensions/` |
| webspaces | named site collections |
| webview-hints | per-site theme (follows the app's by default; no app-bar toggle), color-scheme, matchMedia, a file import's theme prelude |
| webview-pause-lifecycle | per-instance vs process-global pause; "paused != frozen" |
| worker-shim-propagation | installs the per-site shims into Worker/SharedWorker scopes (blob wrapper); page and worker must report identical values |

## JS shim tests (jsdom + node:test)

Every page script is a file in `lib/js/` (Style above). Spec: [js-shim-tests](openspec/specs/js-shim-tests/spec.md).

- **Dart** — `test/*_test.dart` asserts the config a builder derives from a site's settings; [test/page_js_test.dart](test/page_js_test.dart) holds `PageJs`'s own contract. `test/flutter_test_config.dart` loads `lib/js` for every Dart test.
- **Node** — `test/js/*.test.js` runs the script in jsdom through `pageJs(name, config)` ([test/js/helpers/page_js.js](test/js/helpers/page_js.js)), which reads `lib/js` the way `PageJs` does. No Flutter needed.
- **Test code** — the test files are linted by [eslint.config.js](eslint.config.js), in an editor and by `test/js/test_js_lint.test.js`. Code a test runs in a page, worker or jsdom realm is a function, passed to `page.evaluate(fn, ...args)` or turned into text by `scriptOf(fn, ...args)` ([script_of.js](test/js/helpers/script_of.js)); a multi-line template that parses as JavaScript fails the lint. An HTML page keeps its script tags.

Workflow: edit `lib/js/<name>.js` → `npm run test:js`, which also runs ESLint over every script with its parts included. A new script is the file, a `PageJs` value and a sample config in [page_js_samples.js](test/js/helpers/page_js_samples.js), which the all-scripts gates run. A value it needs is a `CONFIG.<key>` read, passed by `withConfig({...})` in its Dart builder; code several scripts share is a `_<name>.js` part pulled in with `// @include _<name>.js`. Configs more than one test uses live in `test/js/helpers/` (`location_configs.js`, `capture_shims.js`, `ua_identities.js`, `worker_shims.js`, `content_blocker_samples.js`).

**Shims that also run in workers** (anything in `workerScopeBodies` in [worker_shim.dart](lib/services/worker_shim.dart); the scripts themselves are in `lib/js/` — see [worker-shim-propagation](openspec/specs/worker-shim-propagation/spec.md)) must be scope-agnostic: `globalThis` never `window`, navigator prototype via `Object.getPrototypeOf(navigator)` never `Navigator.prototype`, window-only sections (`Screen`, `document`, `matchMedia`, `RTCPeerConnection`, `plugins`/`getBattery`) guarded, and never *add* a property a real `WorkerNavigator` lacks. The payload is one script of concatenated IIFEs, so an uncaught `ReferenceError` in one silences every shim after it; `test/worker_shim_test.dart` gates this structurally.

jsdom has no canvas/WebGL/audio fingerprinting. Tests assert override **shape**, not engine behavior. Effects that need a real engine (canvas `captureStream`, Intl timezone math, real CSP, RTCPeerConnection semantics) go in the **browser tier** under `test/browser/` (Puppeteer + headless Chromium, `npm run test:browser`, run in CI's `validate` job). Use the `setupBrowser`/`requireBrowser`/`pageJs` helpers in [test/browser/helpers/launch.js](test/browser/helpers/launch.js) — the tier hard-fails when `CI=true` and no Chromium is found, and skips locally. Example: `camera_stream_real_engine.test.js` serves a page from `127.0.0.1` (getUserMedia needs a secure context), feeds the camera shim a QR image, and asserts jsQR decodes it off the synthetic stream.

## Fastlane changelogs

Files under `fastlane/metadata/android/en-US/changelogs/<N>.txt` (`<N>` is the build number after `+` in `pubspec.yaml`, and the script fails when its file is missing) and sibling descriptions: **each changelog and the full description ≤ 500 bytes; short_description ≤ 80 bytes (no trailing dot)**. Run [scripts/validate_fastlane_metadata.sh](scripts/validate_fastlane_metadata.sh) before committing — oversize silently breaks F-Droid sync.

## Adding a new global app setting

A user-facing global pref is one entry of the `AppPref` enum; persistence, backup export/import, the demo-mode guard and the live value come with it.

1. Declare it in [lib/settings/app_prefs.dart](lib/settings/app_prefs.dart): `name('sharedPrefsKey', fallback: default)`, a `bool`, `int` or `String` (a const assert rejects anything else). Declaration order is the order a backup lists it.
2. Bind its row: a switch is `SettingTile(..., control: const PrefToggle(AppPref.name))`; anything else reads `AppPref.name.value` and writes `AppPref.name.set(v)`. Code with a side effect listens on `AppPref.name.listenable`; the page rebuilds on `AppPref.anyChange`.

- No per-pref constructor params, `_saveX` methods or second cache of the value: `set` persists (except in demo mode) and every reader sees the same notifier. `writeExportedAppPrefs` applies an import to disk and to the running app.
- The integrity test in [test/settings_backup_test.dart](test/settings_backup_test.dart) iterates `AppPref.values` — no test edit needed.
- Don't register: migration flags, download timestamps, cache indices, machine state from downloaded data (DNS blocklist, content blocker, localcdn).
- Per-site settings ride `WebViewModel.toJson` automatically — keep them on the model.
- Touched export/import? Re-run `flutter test test/settings_backup_test.dart test/settings_backup_compat_test.dart`.
- Import logic lives in `planSettingsImport` ([settings_import_engine.dart](lib/services/settings_import_engine.dart)); `BackupController.import` only applies the plan (BACKUP-013).
- Renaming a persisted key (site JSON, backup field, SharedPreferences key) keeps reading the old name and carries the value over (for an `AppPref`, `legacyKey: 'old'`); dropping one is declared with its reason (`_renamedKeys` / `_retiredKeys` in the compat test, `RETIRED` in `test/js/prefs_key_history.test.js`). Both tests hold every release's writes against today's reads (BACKUP-012, BACKUP-014).
- A new `fromJson` field reads a wrong-typed value as absent, never with a bare cast: a site whose JSON throws is dropped at startup and deleted by the next save. An `AppPref` coerces its stored value itself; never read one with `prefs.getBool(AppPref.x.key)` and friends (gated by `test/js/prefs_key_history.test.js`).
- A release commits `test/fixtures/backup_compat/v<version>/` ([docs/releasing.md](docs/releasing.md)); the compat test fails without it, and fails on any PR whose new pref or site field `tool/backup_compat/superset.json` leaves out.

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

Spec: [openspec/specs/localization/spec.md](openspec/specs/localization/spec.md). UI strings go through ARB, never hardcoded literals.

- Add the key + a non-empty `description` (and `placeholders` for interpolation) to [lib/l10n/app_en.arb](lib/l10n/app_en.arb). Reference it via `AppLocalizations.of(context).<key>`.
- **Commit the 66 translated ARBs separately from the code** (see Git above): code + `app_en.arb` first, translations second, pushed together.
- The ARB files ship as assets and the app reads the active locale's at run time (L10N-012); only the typed `AppLocalizations` API is generated, into `lib/l10n/gen/`, which is **gitignored**. `tool/gen_l10n.dart` writes it and fails on an ARB that does not parse; Gradle, Xcode and CMake run it before compiling Dart, and `flutter test`, `dart analyze` and a web build need `fvm dart tool/gen_l10n.dart` after `pub get`. Don't commit its output.
- Pure-data display (e.g. `host:port`) goes into a local variable first; never a string literal inside `Text(`/`tooltip:` etc., or the L10N-002 guard fails.
- [test/js/l10n_no_hardcoded_text.test.js](test/js/l10n_no_hardcoded_text.test.js) and [design_tokens_no_literals](test/js/design_tokens_no_literals.test.js) scan `lib/main.dart`, `lib/app.dart` and every file under `lib/{screens,widgets}`, so a new UI file there needs no edit. Each keeps a shrinking exemption list: drop a file from it once converted.
- Every key MUST carry a non-empty `description` (enforced by [test/js/l10n_coverage.test.js](test/js/l10n_coverage.test.js)) — that description is the context a translator/general model uses, so write it for someone who can't see the screen.
- To add a locale: hand `app_en.arb` (values + descriptions) to any general-purpose model, ask it to translate the values keeping `{placeholder}` tokens verbatim, save as `app_<locale>.arb`. No committed script or API key. Coverage (key + placeholder parity, no empties) is enforced by [test/js/l10n_coverage.test.js](test/js/l10n_coverage.test.js).
- Language identity (file actually written in its claimed language, not left in English or swapped) is enforced by [test/js/l10n_language.test.js](test/js/l10n_language.test.js) (runs under `npm run test:js`, no VRAM). Three checks, all backed by [test/js/helpers/l10n_language.js](test/js/helpers/l10n_language.js):
  - **Whole-file**: CLD3 via `cld3-asm` (pure WASM, no native build/model download) detects each file's language. Three benign code aliases (`he`→`iw`, `nb`→`no`, `bs`↔`hr`); a new locale needs an `ACCEPT` entry only if CLD3 reports a code other than its region-stripped stem.
  - **Han variant**: CLD3 reports both Chinese variants as `zh` and both are Han
    script, so a Traditional file shipped as Simplified passes every other check.
    `hanVariant()` counts variant-exclusive characters and requires each Chinese
    locale to carry its own. Exactly one Chinese locale ships and it is
    Traditional, under the base code `zh` (`zh` is BCP-47 for Chinese, not for
    Simplified) — `tool/gen_l10n.dart` requires a base file beside any
    script- or region-qualified one, so a `zh_Hant`-only setup cannot ship.
  - **Per-string**: flags individual values left untranslated (in English) when neighbours were translated — CLD3 is unreliable on single short strings, so this uses heuristics (non-Latin: a Latin-only multi-word value where the locale's script is expected; Latin: a value whose words are almost all English-source vocabulary plus an unambiguous English stopword). No allowlist — translate the offender. Run `node tool/check_l10n_language.js --per-string [locale]` for the report.
- Nested-webview rule applies to copy too: localized strings in `launchUrl`/`InAppWebViewScreen` flow through `BuildContext`, so resolve them at the call site.
- Widget tests pump a screen/widget through `pumpLocalized(tester, home: child)` or wrap it in `localizedApp(child)` ([test/helpers/localized.dart](test/helpers/localized.dart)); a bare `MaterialApp` leaves `AppLocalizations.of(context)` null.

## Touching the webspace archive

Spec: [openspec/specs/archive/spec.md](openspec/specs/archive/spec.md). Two rules that must hold for any change to archive code:

- **Active-state byte-identity (ARCH-001).** Everything persisted under the device-key path of `flutter_secure_storage` or in plaintext `SharedPreferences` MUST be byte-identical regardless of whether the device has zero or N archives where all are closed. No counter, flag, salt, MRU entry, or feature-touched marker may vary with archive presence or count. Settings export/import operates only on the app-tier collections and never serializes archive-tier state. Regression test: `test/archive_neutrality_test.dart` (asserts this invariant; update when you add app-tier state).
- **Per-site feature audit (ARCH-006).** When adding any new per-site feature, re-run the audit in the spec. Per-site features that touch disk, background scheduling, OS-level UI, or per-`siteId` entries outside the archive's MK keyspace MUST be disabled or routed through the archive MK for archive-tier sites — extend the override matrix in `WebViewModel` rather than handling it at call sites.

Argon2id derivation costs ~1s on target hardware. Keep it off the UI thread on startup paths and inside a "decrypting..." progress affordance on user-initiated unlocks.

## Adding a new credential / secret

Follow [openspec/specs/proxy-password-secure-storage/spec.md](openspec/specs/proxy-password-secure-storage/spec.md). Template: `ProxyPasswordSecureStorage`.

- **Storage**: a `SecureJsonStore` ([keystore.dart](lib/services/keystore.dart)) on `Keystores.credentials`, keyed by `siteId` (per-site) or a fixed reserved key (global). Never a new `FlutterSecureStorage` option set: on Apple the accessibility class is part of the keychain query, so changing it makes existing entries unreadable ([BUG-027](docs/bugs/027-aead-keys-unreadable-on-locked-wake.md)). An encrypted blob on disk takes its key from `KeychainAead`.
- **Never serialise to JSON**: `toJson` omits the field. No `includeSecrets` opt-in. Same rule as `isSecure=true` cookies. Backup files get emailed/synced — they must not carry secrets.
- **Hydrate on load** alongside per-site/global hydration in `SiteListStore.load` and `GlobalOutboundProxy.initialize`.
- **Migrate legacy plaintext** with the idempotent pre-pass in `ProxyPasswordSecureStorage.migrateLegacyPassword`.
- **Wire orphan cleanup**: add the store to `OrphanStore` in [orphan_sweep_engine.dart](lib/services/orphan_sweep_engine.dart) with its scope (session residue or configuration). `PageOrphanSweep` ([page_orphan_sweep.dart](lib/controllers/page_orphan_sweep.dart)) does not compile until it sweeps the store; startup, post-import and post-delete all run the engine.
- **Tell the user post-import** (snackbar in `BackupController.import`) if the related non-secret field was set — otherwise restored proxy silently fails auth.
- **Regression test**: assert the secret string never appears in `SettingsBackupService.exportToJson(...)` output. Template: "proxy passwords never appear in exports (PWD-005)".
- Update the spec, then `npx openspec validate --no-interactive --all`.

## Per-site web push notifications

`notificationsEnabled` (per-site) folds three behaviors so a single user toggle keeps notifications reliable:

- **Polyfill**: JS `Notification` constructor + `requestPermission()` are polyfilled at `DOCUMENT_START` (`ShimFrames.all`); calls bridge to `NotificationService` via `addJavaScriptHandler('webNotification', ...)`.
- **No per-instance pause**: `WebViewModel.pauseWebView()` early-returns for notification sites — iOS's `pauseTimers()` alert hack would freeze the JS thread between site switches and queue setTimeouts into one burst on resume.
- **No app-background JS pause while one exists** (NOTIF-011): Android's `pauseTimers()` is process-global and reaches webviews built after it, so any notification site vetoes it, not only an active or loaded one: a wake's headless check of an unloaded one stalls under it.
- **Auto-load + retention priority**: notification sites load at launch once the launched site's first load settles (at most `kLaunchLoadWait`), each as a preload (an activation that does not show, NOTIF-017), and tier `notification` in `SiteRetentionPriority` so OS memory pressure evicts other sites first.
- **iOS background contract** (NOTIF-005-I): `BackgroundTaskService` calls `UIApplication.beginBackgroundTask` on app-pause for a ~30s grace window and registers a `BGAppRefreshTask` (`org.codeberg.theoden8.webspace.notification-refresh`) that reloads notif sites opportunistically. Native bridge: [`ios/Runner/BackgroundTaskPlugin.swift`](ios/Runner/BackgroundTaskPlugin.swift).
- **A wake ends when its pages have loaded** (NOTIF-013): returning from `onBackgroundRefresh` completes the OS task, so `BackgroundSitesController.wake` awaits `BackgroundWakeEngine`, which waits for the reloads to settle. A reload shows what arrived but a site need not notify for it, so a site that stayed silent while its title's unread count rose gets one post on its behalf (NOTIF-014). iOS has no way to run a page between wakes: no foreground service, no Web Push in WKWebView apps, and keep-awake tricks fail App Store review.
- **A wake checks every notification site** (NOTIF-016), not only loaded ones with a webview: in a process the OS launched for the wake there is no webview at all. `BackgroundWakeEngine.plan` decides from `wakeCandidateFor` (live: reload; else `WebViewFactory.openHeadlessCheck` with `WebViewModel.headlessCheckConfig`, which takes the site's `SitePosture` as `getWebView` does and the host hooks `unattended()`; else skip with a `WakeSkip` reason). Each headless check asks the activation's `RouteFree` as it opens and waits out an activation in flight; the wake runs from a step table `activation.tla` takes whole. Lineage: [BUG-024](docs/bugs/024-background-notifications-never-arrive.md), [BUG-037](docs/bugs/037-background-load-on-another-route.md).
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
[BUG-025](docs/bugs/025-nested-posture-drift.md).

When you add a per-site field:

1. A `SiteField` case ([lib/settings/site_field.dart](lib/settings/site_field.dart):
   its key, any older keys, whether a QR carries it) and its arms in the save
   and read switches of [web_view_model_json.dart](lib/web_view_model_json.dart).
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
cookie jars) is one `WebViewHostHooks`
([webview_host_hooks.dart](lib/services/webview_host_hooks.dart)) that
the page builds once and both surfaces take whole; a new host answer is a
required field there (BUG-028). The site's own webview takes it inside a
`SiteHooks` ([web_view_model_hooks.dart](lib/web_view_model_hooks.dart)),
beside the answers that name the site, which a nested screen never asks.

If the field controls JS in `initialUserScripts`, inject it with `pageShim(..., frames: ShimFrames.all)` ([page_shim.dart](lib/services/page_shim.dart)) so the shim reaches cross-origin iframes.

## Logic engine vs rendering engine

Orchestration (which sites unload on switch, how indices shift after delete, what cookies move during activation) → pure-Dart engine in `lib/services/*_engine.dart`. Template: [cookie_isolation.dart](lib/services/cookie_isolation.dart). Native webview / platform channels / `setState` stays at the call site.

- Mutating `SiteRuntime`'s models, loaded sites or webspaces with >1 line of index arithmetic? Engine.
- Which loaded sites go, and why? A `ResidencyEvent` case in `SiteUnloadEngine.plan` ([site_unload_engine.dart](lib/services/site_unload_engine.dart)), run by `SiteUnloadEngine.apply`; every eviction picks through `evictionOrder`. Never unload from a loop at a call site.
- `await native_call` then mutate shared state with scenario-dependent logic? Engine.
- Engines never `import 'package:flutter/material.dart'`, never call `setState`, never touch `context`. Add interfaces on existing services (e.g. `CookieManager`) instead of reaching into concrete types.
- Race protection: pass `versionAtEntry:` and `currentVersion:` (an `int Function()`) so the engine can bail without knowing about widget state.
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

Test harness re-implementing `switchToSite`/`deleteSite` = un-extracted engine. Wrap the real engine; never re-write the flow in a test. See `CookieIsolationTestHarness` in [test/cookie_isolation_integration_test.dart](test/cookie_isolation_integration_test.dart), whose site list is `SiteListState` ([test/helpers/site_list_state.dart](test/helpers/site_list_state.dart)), the production `SiteRuntime`.

## Code flows new → stable

New features extend the engine (or add one alongside). Never inline a feature-specific branch into a stable call site; never copy stable engine logic into a new-feature path. A `_WebSpacePageState` method reads as engine calls + persistence/UI side-effects.

## UI race conditions

Async UI handlers (button callbacks, `onPopInvokedWithResult`, gestures) get re-entered before the first call resolves.

- **Rapid input**: a handler that `await`s before acting can be entered twice concurrently.
- **Guard**: a [`ReentryGuard`](lib/services/reentry_guard.dart) field, `await _guard.run(() async {...})`; `run` owns the `finally`, so no exit path leaves it held.
- **Waiting, not dropping**: a `SerialQueue` named for its lock class. It is not re-entrant: a step that runs inside the turn is a member marked `@Held(#queue)`, which the `held_in_turn` analyzer rule lets run only in that queue's turn, with its future awaited there; never a second `run` (which `LockOrder` refuses as a self-wait), and work queued behind the turn is `enqueue`. A member reached only through an interface the rule cannot follow asserts `queue.isHeld` instead, with the hop named. A recursive mutex is no fix in Dart: a hold is a zone, and work the holder left running would get back in mid-change.
- **State across awaits**: re-check `mounted`, indices, shared state — another handler may have mutated.
- **Drawer/dialog flash**: opening UI in an unguarded async callback lets a second tap close it immediately.
