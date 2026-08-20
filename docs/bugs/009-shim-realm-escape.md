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

## Known open gaps

- **Realms not yet compared against the document:** workers spawned by a
  `SharedWorker`, service workers, and frames whose documents the native
  injection scope may not reach (`about:blank`, `srcdoc`, sandboxed). The
  browser tier can only model injection scope, not reproduce it — the native
  `forMainFrameOnly` / all-frames decision is what actually settles frames, so
  a real-device check is the honest gate there.
- **A site can break its own workers to opt out of the wrapper.** A CSP whose
  `worker-src` omits `blob:` blocks the wrapper script, and because CSP surfaces
  that as an async `error` event rather than a constructor throw, the fail-open
  fallback in `WORK-006` never runs and no worker starts. No unshimmed realm
  appears, so the spoof holds, but the site's workers stop working — and any fix
  that keeps them running must keep them shimmed, or it converts this into a
  real escape. Pinned by `test/browser/worker_realm_escape.test.js`.
- **The `__ws*` install markers remain enumerable** on `globalThis` in worker
  scope as well as on `window`, so a fingerprinter can detect that *a* shim is
  present even when it cannot read past it. Repo-wide convention issue, tracked
  as `t.todo` in `test/browser/lie_detection.test.js` and
  `test/browser/worker_realm_escape.test.js`; fixing it means moving the whole
  convention to Symbols.
