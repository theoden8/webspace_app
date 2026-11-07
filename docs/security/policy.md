# Access policy

What a hostile page may and may not reach inside WebSpace, and the code that
decides each answer. [lab.md](lab.md) designs the evaluation that tests it; the
review runs in this directory report against it.

A rule names the requirements that state it. How strongly each requirement is
checked is not written here: `node tool/spec_map.js --policy` prints it from
the checks that name each one, so it cannot go stale. A requirement is proved
by a model (TLC or TLAPS), by a compile probe, a test that shows the
compiler rejecting the mistake, or by a `webspace_lints` rule at error
severity with its own test; an assert, a test or a source gate is evidence. A requirement counts as proved by its strongest check, which proves
its central claim; details it lists beside that claim may rest on tests, so
read the checks `spec_map.js` names before relying on one. A requirement nothing proves yet is owed in
[policy_debt.tsv](policy_debt.tsv), with the kind of check that will close it
and what that check is, and the list only shrinks:
[test/js/security_policy.test.js](../../test/js/security_policy.test.js) fails
on a rule's requirement nothing proves and no row owes, and on a row whose
requirement is proved now.

## Subjects

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

## Objects

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

## Rules

Default deny: a request no rule allows is refused. Complete mediation: every
request passes one check at the component that owns the object, never at a
reader of it.

| Rule | Allowed | Owner | Requirements |
|---|---|---|---|
| R1 storage | a document reads and writes only its own origin's storage, in its site's container; in legacy mode, only its site's cookies are in the jar while it runs | `lib/services/container_isolation_engine.dart`, `lib/services/container_names.dart`, `lib/services/cookie_isolation.dart` | CONT-003, CONT-005, ISO-001, ISO-002, ISO-006, INC-001 |
| R2 grants | a capability grant serves only the site's own documents; a foreign document is asked for itself, and its answer stays with its origin | `lib/services/media_grant_engine.dart`, `lib/services/site_origins.dart`, `lib/services/page_handlers.dart` | PERM-001, PERM-002 |
| R3 frames | a cross-origin frame inside the site's own document gets no device grant and no live location; the site's device-free answers only | `lib/services/media_grant_engine.dart`, `lib/services/page_handlers.dart` | CAM-014, MIC-016, LOC-011 |
| R4 identity | nothing the page passes names a site, origin, frame, tab or download | `lib/services/page_handlers.dart` | NOTIF-010, CAM-013, PASSKEY-004 |
| R5 documents | a result decided for one document lands in that document only | `lib/services/page_phase.dart` | US-007 |
| R6 surfaces | a share, a capture or a prompt ends when its document, view or site leaves the screen | `lib/services/screen_share.dart`, `lib/services/media_grant_engine.dart` | SHARE-017, SHARE-018, CAM-011 |
| R7 import | an imported file creates no authority: no `real` grant, no enabled script, no live location, no notification permission without a fresh local consent | `lib/settings_import_engine.dart`, `lib/controllers/archive_controller.dart` | BACKUP-010, BACKUP-011, BACKUP-013, ARCH-015 |
| R8 identity uniqueness | two site records never share a container, and a removed site leaves no container behind | `lib/settings/site_ids.dart`, `lib/settings_import_engine.dart`, `lib/controllers/archive_controller.dart` | ARCH-007, CONT-010 |
| R9 routes | a site behind a proxy or Tor never loads direct, nor on another site's route | `lib/services/process_route.dart`, `lib/services/outbound_http_types.dart` | PROXY-008, LEAK-002, LEAK-003 |
| R10 navigation | a frame cannot steer the top document; a gesture-less cross-domain hop is refused; a popup kind is decided by the app, not the page | `lib/services/navigation_decision_engine.dart`, `lib/services/popup_webview.dart` | NESTED-013, CAPTCHA-007 |

The asynchronous cases follow from R2 and R5:
- **A prompt answered after a navigation** serves the origin it named, never the document that replaced it.
- **A redirect, a popup or a worker** carries no standing of its own. Its origin, read from the platform, decides it.
- **Revocation and disposal** end the grant at the store, which every later request reads.

## Trusted base

What the rules above take as given rather than check.

- **The engines, the OS and the keystore.** Their own defects are outside this
  policy; their known advisories are not: every tracked lockfile is scanned
  against OSV in CI (`scripts/osv_scan.sh`, `accepted_advisories.tsv`).
- **A frame's identity at the bridge.** R2, R3 and R4 decide by the origin and
  main-frame flag `JavaScriptHandlerFunctionData` carries, which the plugin fork
  (`theoden8/flutter_inappwebview`) supplies. Where it comes from differs by
  platform, so those rules hold only as far as it does:

  | Platform | Origin | Main frame |
  |---|---|---|
  | iOS, macOS | WebKit's `frameInfo.securityOrigin` | WebKit's `frameInfo.isMainFrame` |
  | Android | the bridge script in the frame | the bridge script in the frame |
  | Linux | the webview's current URL, the top document's for every frame | the bridge script in the frame |

  On Android and Linux the bridge script's values are accepted on a secret the
  fork makes per webview. Platform-supplied identity there is owed in
  [policy_debt.tsv](policy_debt.tsv).

## Where each layer helps

| Layer | Separates | Cannot separate |
|---|---|---|
| OS mandatory access control (SELinux on Android, the App Sandbox on Apple, AppArmor or a Flatpak/snap profile on Linux) | the app from other apps and the system; on Android the WebView renderer runs in a separate, more confined domain | one site from another: every site runs under the app's one identity, so the OS sees one subject |
| The engine (WebKit, Chromium) | origins, by the same-origin policy; containers, where the engine has them | anything the app hands across, through a bridge, a shared container or a shared jar |
| The app | sites, surfaces and standings, at its bridge, grant store, navigation and import paths | a compromised renderer, which this policy does not cover |

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
