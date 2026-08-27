# BUG-009 — A JS realm reports the real values the per-site shims spoof

Status: open (each escape found so far is closed; the class stays open until
every realm a page can reach is enumerated and covered)

**Spec:** [openspec/specs/worker-shim-propagation/spec.md](../../openspec/specs/worker-shim-propagation/spec.md)
— `WORK-001`, `WORK-002`, `WORK-005`

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

- **The `__ws*` install markers remain enumerable** on `globalThis` in worker
  scope as well as on `window`, so a fingerprinter can detect that *a* shim is
  present even when it cannot read past it. Repo-wide convention issue, tracked
  as `t.todo` in `test/browser/lie_detection.test.js` and
  `test/browser/worker_realm_escape.test.js`; fixing it means moving the whole
  convention to Symbols.
