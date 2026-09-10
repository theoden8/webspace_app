# BUG-009 — A JS realm reports the real values the per-site shims spoof

Status: open (each escape found so far is closed; the class stays open until
every realm a page can reach is enumerated and covered)

**Spec:** [openspec/specs/worker-shim-propagation/spec.md](../../openspec/specs/worker-shim-propagation/spec.md)
— `WORK-001`, `WORK-002`, `WORK-005`, `WORK-007`; the cross-shim rule is
[`ETP-025`](../../openspec/specs/tracking-protection/spec.md)

## Symptom

The document reports the per-site spoofed identity (language, timezone,
User-Agent, core count, memory, canvas noise) but some *other* JS realm the same
page can reach reports the machine's real values. A fingerprinter does not have
to break the spoof — it reads the honest realm instead, and the disagreement
between the two is itself a stronger signal than either value alone. CreepJS
does exactly this.

## Root mechanism / invariant

Per-site shims are delivered as `UserScript`s, which reach *documents*. Every
other JS global scope a page can create — dedicated workers, module workers,
shared workers, workers spawned by workers, and frames outside the injection
scope — is a separate global that no `UserScript` reaches. Each such scope has to
be covered by an explicit propagation mechanism, and each mechanism has its own
loading semantics (`importScripts` vs static `import` vs native injection).

Coverage is therefore per-path, and a path added or varied later does not inherit
the earlier path's fix. That is what makes this recur: the *feature* is "shims
reach workers", but the *implementation* is one wrapper shape per worker flavour,
and a flavour whose shape differs silently opts out.

The invariant: **every JS realm a page can reach must report values identical to
the document's, and each realm-creating API must be covered by its own tested
path — page/worker agreement in one flavour is not evidence for another.**

## Fix attempts

1. **2026-07-31 — worker-shim-propagation feature** (`WORK-001`…`WORK-006`, bbc63f9, #519).
   Patched `Worker`/`SharedWorker` so the requested script is replaced by a
   generated `blob:` wrapper that loads the shim payload first and the original
   script second. *Why:* a worker was a total bypass of every JS-side spoof —
   a site configured for English/UTC reported `es-ES` and `Europe/London` from
   its worker. *Why partial:* the wrapper has two shapes. The classic shape
   (`importScripts`) assigns `self.__wsShimUrl` before importing, which is what
   the payload's tail reads to re-install the constructor patch inside the
   worker (`WORK-005`, nested coverage). The module shape (static `import`) was
   written without that assignment, so nested coverage was classic-only. Nothing
   tested a module worker's *children*, so the gap did not surface.

2. **2026-08-20 — module wrappers deliver `__wsShimUrl` via an imported module**
   ([lib/services/worker_shim.dart](../../lib/services/worker_shim.dart)).
   The module wrapper now statically imports a small generated module that
   assigns `globalThis.__wsShimUrl` ahead of the shim import. *Why:* module
   evaluation is hoisted, so an assignment written in the wrapper body runs
   *after* both imports — the payload's tail found nothing and skipped
   re-installing the patch. `new Worker(x, {type:'module'})` then `new Worker(y)`
   read the real `hardwareConcurrency` and `deviceMemory` straight through: two
   lines of page script to escape every JS-side spoof. Found by
   `test/browser/worker_realm_escape.test.js`, which compares the document
   against classic, module, and nested-in-each realms under a real engine.
   *Why partial:* it covers the realms that test enumerates. `SharedWorker`
   children, service workers, and `about:blank` / `srcdoc` / sandboxed frames
   are not yet compared against the document.

3. **2026-08-27 — the blob-less-CSP refusal is detected, and falls open**
   ([lib/services/worker_shim.dart](../../lib/services/worker_shim.dart)).
   The page-side installer starts one throwaway `blob:` worker at document start
   and records what the engine says. A refusal — that probe's `error` event, or a
   `securitypolicyviolation` naming a `blob:` URI under a directive that governs
   worker scripts — stops all further wrapping in that document, and the classic
   wrapper's shim `importScripts` is now caught so a refusal one checkpoint later
   costs the same thing. *Why:* messenger.com sends `worker-src` without `blob:`.
   Every wrapper was refused asynchronously, no `WORK-006` fallback ran, and the
   chat worker never started: the account stayed logged in while "Enter your PIN
   to restore chats" sat on "verifying…" forever, with no error and no timeout
   (issue #560). *Why partial:* it trades this breakage for the escape listed
   below it. Under such a CSP the worker now runs unshimmed and reports the real
   hardware against a spoofed document. No wrapper shape can preload a shim past
   that policy — closing it means delivering the shim *with* the worker script
   (a network-layer rewrite of the response) instead of in place of it. And a
   worker built before the probe answers, from an inline script at the top of the
   document, still gets a wrapper that never loads.

4. **2026-08-27 — wrapper prototypes stop handing back the native constructor**
   ([lib/services/worker_shim.dart](../../lib/services/worker_shim.dart),
   [lib/services/location_spoof_service.dart](../../lib/services/location_spoof_service.dart),
   [lib/services/language_shim.dart](../../lib/services/language_shim.dart)).
   Four wrappers did `Patched.prototype = Real.prototype`, which takes the
   native prototype *object* — whose own `constructor` property still points at
   the native constructor. Each now re-points it with a guarded
   `Object.defineProperty(Patched.prototype, 'constructor', {value: Patched,
   writable: true, configurable: true})`. *Why:* this is the realm class the
   earlier attempts did not consider — not a scope the shim fails to reach, but
   the unpatched constructor left reachable *inside* a scope the shim did
   reach. `new (Worker.prototype.constructor)('probe.js')` produced a worker
   that never saw the blob wrapper and reported real
   `hardwareConcurrency`/`deviceMemory`/`languages`/`userAgent`/timezone against
   a spoofed document — the same `WORK-002` disagreement attempt 2 closed,
   through a different door, and reachable in one expression with no CSP, no
   module worker, and no nested spawn. The `relayOnly` RTC wrapper was the worst
   of the four: `new (RTCPeerConnection.prototype.constructor)({iceServers})`
   gave a native peer connection with `iceTransportPolicy` defaulting to `all`
   and no SDP candidate filter, and Chromium's ICE gathering does not follow the
   HTTP/SOCKS proxy — so the real LAN and public IP went out on the wire from a
   site configured `webRtcPolicy: relayOnly`. `asNative` did not cover this: it
   only registers a `toString` stub in `__wsFnStubs` and never touches
   `constructor`. The worker fix lives in `_installerDefinition`, shared verbatim
   by the page installer and the payload's nested-worker tail, so a
   worker-spawned worker gets it on the same terms. *Why partial:* it covers the
   four wrappers that exist today, in whatever realm the shim itself runs. It
   does nothing for a realm the payload never reaches (the gaps below stand
   unchanged), and nothing for a wrapper that leaks its native original by some
   other route — a captured reference held in a closure, a `Reflect.construct`
   over a stashed prototype, or an iframe's `contentWindow` constructors. The
   class-level guard is structural, not behavioural: `test/js/shim_prototype_constructor.test.js`
   fails when a new `X.prototype = Y.prototype` appears in a shim source without
   an adjacent re-point, so the *next* instance of this exact shape fails CI,
   but a wrapper built some other way is invisible to it.

5. **2026-09-06 — the wrapper the answer arrives too late for is rebuilt**
   ([lib/services/worker_shim.dart](../../lib/services/worker_shim.dart)).
   A dedicated worker wrapped while the CSP verdict is still outstanding now
   keeps what rebuilding it takes, and on a refusal is rebuilt on the page's own
   script *behind the object the page already holds*: `postMessage` and
   `terminate` forwarded to the rebuilt worker, its `message` / `messageerror` /
   `error` events re-dispatched on the original, and the messages posted before
   the swap replayed in order. *Why:* attempt 3 left this window open and said
   so. The probe's answer is a task away, so a worker built from an inline
   script at the top of the document is handed a wrapper before any verdict
   exists; under a CSP whose `worker-src` names hosts and no `blob:`
   (github.com's shape) that wrapper is refused *after* its constructor
   returned, so no fail-open branch sees it and the page holds a worker that
   never starts — #560's failure one turn earlier. Nothing measured it: every
   CSP test built its worker after `load`, by which time the probe had long
   answered. *Why partial:* dedicated workers only. A `SharedWorker` built in
   the same window still dies, because the page takes its `MessagePort` at
   construction and a port cannot be re-entangled with a second worker. The
   discriminator between a refusal and the site's own worker throwing is the
   error's message (a refusal reaches no script, so it carries none), which is
   chromium's shape; an engine that reports a refused worker *with* a message
   falls back to attempt 3's behaviour. And the rebuilt worker is unshimmed, so
   what stands at the end of it is still the WORK-006 trade, one turn later.

6. **2026-09-07 — nothing is asked of the CSP until the page wants a worker**
   ([lib/services/worker_shim.dart](../../lib/services/worker_shim.dart)).
   The document-start probe is gone. The site's own first worker is the test
   instead: it gets a wrapper, its refusal is the answer, and attempt 5's
   rescue is what makes that survivable. The rescue now covers `SharedWorker`
   too, by handing the page one end of a `MessageChannel` in place of the
   worker's port and re-pointing the other end at the rebuilt worker, so
   nothing regressed by dropping the probe that used to protect it. Any
   enforced violation the site causes for its own reasons carries
   `originalPolicy`, which is parsed for the same answer when it arrives first
   — the one time the platform hands a page its own policy. *Why:* the probe
   was a beacon. A page cannot read a header-delivered CSP, so testing meant
   breaking it, and testing up front broke it on every load of every refusing
   site whether or not the page had a use for a worker. github.com's
   `worker-src` names hosts and no `blob:`, so each load logged a refusal that
   a first party can read off a `securitypolicyviolation` listener and a
   `report-uri` mails home; nothing in a stock browser starts a `blob:` worker
   at document start, so it identified the app — against
   `tracking-protection`'s whole point. *Why partial:* the first worker of a
   refusing document still pays. It costs one violation and, being rebuilt on
   the site's own script, still runs unshimmed. Only reading the policy where a
   page cannot forge it answers for free, and that is platform-shaped (see the
   gap below). The directive filter also narrowed to worker-governing
   directives, so an engine that reports only `violatedDirective` on a worker
   refusal now falls through to the rescue rather than pre-empting it.

7. **2026-09-10 — the relay policy moves onto the prototype**
   ([lib/services/location_spoof_service.dart](../../lib/services/location_spoof_service.dart)).
   `relayOnly` forced `iceTransportPolicy` only in the constructor and filtered
   SDP only through a wrapper written onto the instance.
   `RTCPeerConnection.prototype.setConfiguration` is native and may change the
   policy, `prototype.setLocalDescription.call(pc, ...)` skipped the instance
   wrapper, and the argument-less `setLocalDescription()` never passed SDP
   through it, so a page pinned to `relayOnly` behind a proxy could gather host
   candidates and read its public IP off `onicecandidate`. Both methods are now
   patched on the prototype (the policy is forced on every configuration, the
   filter runs whichever way the method is reached) and the constructor no
   longer writes onto the caller's object. *Why:* the same shape as attempt 4,
   the native original reachable inside a scope the shim reaches, through the
   prototype's methods rather than its `constructor`. *Why partial:* a reference
   to the native prototype methods captured before the shim ran, or an iframe
   realm the payload never reaches, still holds the original, and the shim has
   no native enforcement behind it on any platform. Class-level guard:
   `test/js/location_spoof_shim.test.js` (`setConfiguration`, the prototype
   call, the argument-less call) and the LOC-004 scenario.

## Known open gaps

- **Realms not yet compared against the document:** workers spawned by a
  `SharedWorker`, service workers, and frames whose documents the native
  injection scope may not reach (`about:blank`, `srcdoc`, sandboxed). The
  browser tier can only model injection scope, not reproduce it — the native
  `forMainFrameOnly` / all-frames decision is what actually settles frames, so
  a real-device check is the honest gate there.
- **A site can opt its workers out of the shim with one directive.** A CSP whose
  `worker-src` omits `blob:` refuses every wrapper. Since attempt 3 the installer
  detects that and hands the constructor the site's own script, so the workers
  run — unshimmed, which is a live page/worker disagreement the site chose to
  create. It is the widest deliberate hole, and it costs a site one directive to
  open. Closing it means delivering the shim with the worker script rather than
  instead of it: page JS cannot, since it cannot serve a same-origin URL, so it
  would have to be the network layer rewriting the response (Android has
  `WebInterceptPlugin`; WKWebView has no equivalent for http(s)). Pinned in
  `test/browser/worker_realm_escape.test.js` against messenger.com's CSP shape.
- **The fail-open path (`WORK-006`) is itself an escape where it fires.** When
  wrapping fails synchronously — `URL.createObjectURL` throwing, or an engine
  refusing a `blob:` worker at construction — the original script is handed to
  the real constructor and the resulting worker runs unshimmed, reporting the
  real hardware against a spoofed document. The spec accepts that trade
  explicitly ("a broken worker is worse than an unspoofed one"), so this is a
  design decision to revisit rather than a bug to patch. Since attempt 3 it also
  fires, deliberately, once the CSP probe reports a refusal — which is what
  widened it from an engine quirk to something any site can trigger. **Unknown:
  which branch WKWebView and Android System WebView take**; on WebKit a
  synchronous refusal reaches the same fallback one step earlier, so the outcome
  matches, but nobody has measured it. All branches are pinned in
  `test/browser/worker_realm_escape.test.js`; settling the native mode needs a
  device.

- **The first worker of a refusing document still costs one CSP violation**, and
  it is first-party observable: a `securitypolicyviolation` listener sees it and
  a policy carrying `report-uri` / `report-to` mails it home. Since attempt 6 a
  page that never builds a worker never touches the policy, but the one that
  does announces the app the same way, once, and then runs unshimmed. No page
  can do better: a header-delivered CSP is invisible to JS, and the only time
  the platform hands a page its own policy is inside a violation report.
  Answering for free means reading the response headers from the embedder side,
  which is platform-shaped. iOS and macOS carry them on `onNavigationResponse`,
  but switching that hook on also disables the `decisionHandler(.download)`
  branch in the fork's `InAppWebView.swift`, so it wants a passive header
  callback rather than the existing policy hook. The Linux fork already holds
  the `WebKitURIResponse` in its response-policy decision
  (`in_app_webview.cc:3864`), one call from the headers. Android's WebView
  exposes response headers only through `onReceivedHttpError`, which fires only
  for status >= 400, so a 200 document's policy cannot be read there at all.
  Note also that this answer must come from the native side, not a page report:
  on Android the JS bridge's `origin` and `isMainFrame` are supplied by the
  injected script itself (`JavaScriptBridgeInterface` reads them out of the
  call's payload), so a page-reported verdict would hand any script a switch to
  take its own origin's workers out of the shim.

- **The `__ws*` install markers remain enumerable** on `globalThis` in worker
  scope as well as on `window`, so a fingerprinter can detect that *a* shim is
  present even when it cannot read past it. Repo-wide convention issue, tracked
  as `t.todo` in `test/browser/lie_detection.test.js` and
  `test/browser/worker_realm_escape.test.js`; fixing it means moving the whole
  convention to Symbols.
