# Worker Shim Propagation Specification

## Status
**Implemented**

## Purpose

Install the per-site JS shims into `Worker` and `SharedWorker` global scopes, so
a page cannot read the real OS/engine values simply by reading them off the main
thread.

Every per-site shim (language, UA identity, timezone, anti-fingerprinting) is
delivered as a `UserScript` injected into the *document*. A worker runs in a
separate global scope that no `UserScript` reaches. Without propagation the
worker is not a partial leak but a **total bypass** of every JS-side spoof, and a
well-known one: CreepJS re-reads locale, timezone, User-Agent, core count and GPU
inside a worker specifically to defeat main-thread-only spoofing, and treats the
page/worker disagreement as its strongest signal. Observed before this feature: a
site configured for English/UTC reported `es-ES` and `Europe/London (-60)` from
its worker.

---

## Requirements

### Requirement: WORK-001 - Shims installed before worker code runs

When at least one per-site shim is active, the app SHALL patch the `Worker` and
`SharedWorker` constructors so the requested script is replaced by a generated
`blob:` script that loads the shim payload FIRST and the original script SECOND:

```
self.__wsShimUrl = "<shim blob>";
importScripts("<shim blob>");
importScripts("<absolute original url>");
```

Both loads are synchronous and ordered, making this the worker-scope equivalent
of `AT_DOCUMENT_START`. The original specifier SHALL be resolved to an absolute
URL (a relative one would resolve against the `blob:` base and fail). Module
workers (`{type: 'module'}`) SHALL instead receive ordered static `import`s,
because `importScripts` does not exist in a module worker and dynamic `import()`
would resolve in a later task, after messages may already have been delivered.

Module evaluation is hoisted, so a module wrapper SHALL deliver `__wsShimUrl`
through its own imported module placed before the shim import, never through an
assignment in the wrapper body — that assignment would run after both imports and
leave the payload with nothing to re-install itself from (see WORK-005).

#### Scenario: Classic worker loads the shim before the site script

**Given** a site with an active per-site shim
**When** the page calls `new Worker('w.js')`
**Then** the real constructor receives a `blob:` URL
**And** that blob imports the shim payload before
`https://<origin>/w.js`

#### Scenario: Module worker uses ordered static imports

**Given** the page calls `new Worker('m.js', {type: 'module'})`
**Then** the wrapper contains no `importScripts`
**And** it statically imports the shim before the original module
**And** it statically imports a module assigning `__wsShimUrl` before both

---

### Requirement: WORK-002 - Page and worker report identical values

The payload SHALL be the SAME shim source injected into the document, not a
worker-specific variant. A worker reporting a different seeded value (for example
`navigator.hardwareConcurrency`) than its own page is itself a fingerprint, so
the shims are scope-agnostic — `globalThis` rather than `window`, the navigator
prototype resolved from the live `navigator` (which is `WorkerNavigator` in a
worker) rather than named as `Navigator` — and one source serves both scopes.

#### Scenario: Seeded hardware values agree across scopes

**Given** the anti-fingerprinting shim is active for a site
**When** the page and its worker both read `navigator.hardwareConcurrency`
**Then** the two values are equal
**And** neither is the host device's real value

#### Scenario: Locale, timezone and identity are spoofed in the worker

**Given** a site set to English/UTC with a Firefox-Android UA
**When** its worker reads locale, timezone and navigator identity
**Then** `navigator.language` is `"en"` and `Intl.NumberFormat().format(0.5)`
is `"0.5"`
**And** `new Date().getTimezoneOffset()` is `0`
**And** `navigator.vendor` is `""` and `navigator.productSub` is `"20100101"`

---

### Requirement: WORK-003 - Never add a property a real worker scope lacks

In worker scope the shims SHALL only correct the value of a property that is
already present, and SHALL NOT add one. A worker's `navigator` legitimately
exposes a smaller surface than a window's, and workers have no
`RTCPeerConnection`, `matchMedia`, `Screen`, or `document` — defining any of those
in worker scope would be a fresh leak, worse than the one being closed:

* `navigator.plugins`, `navigator.mimeTypes`, `navigator.getBattery` — window
  only, skipped in a worker.
* `navigator.oscpu`, `navigator.buildID` — not exposed on `WorkerNavigator`, so
  not added there even for a Gecko UA.
* The WebRTC policy and the `matchMedia` device-dimension wrapper — window only.
* `navigator.userAgentData` — removal still applies (it removes an existing
  property on a Blink host).

`navigator.platform` is therefore set by the UA-identity shim for desktop UAs as
well as mobile ones (see `user-agent-identity`), because a worker never receives
the window-only `desktop-mode` shim that would otherwise set it.

#### Scenario: Window-only navigator properties stay absent in a worker

**Given** the shims are installed in a worker scope
**Then** `'plugins' in navigator`, `'mimeTypes' in navigator`,
`'getBattery' in navigator`, `'oscpu' in navigator` and
`'buildID' in navigator` are all `false`

#### Scenario: Window-only globals stay absent in a worker

**Given** the shims are installed in a worker scope
**Then** `typeof globalThis.RTCPeerConnection` is `"undefined"`
**And** `typeof globalThis.matchMedia` is `"undefined"`

---

### Requirement: WORK-004 - SharedWorker identity preserved

The wrapped `blob:` URL SHALL be cached per (script, module-ness) and reused,
because `SharedWorker` identity is keyed on the script URL. Handing out a fresh
blob per call would silently turn one shared worker into N unshared ones and
break the page.

#### Scenario: Repeated SharedWorker construction shares one wrapper

**Given** the page calls `new SharedWorker('s.js')` twice
**Then** the real constructor receives the same `blob:` URL both times

---

### Requirement: WORK-005 - Nested workers stay covered

The payload SHALL re-install the same constructor patch inside the worker, so a
worker that spawns a worker is also covered (otherwise it is a one-line bypass).
The payload learns its own blob URL from `self.__wsShimUrl`, which the wrapper
assigns before importing it, and SHALL delete that handle after reading it so it
does not linger as an inspectable own-property.

#### Scenario: A worker spawning a worker propagates the shim

**Given** the shim payload is running in a worker
**When** that worker calls `new Worker('inner.js')`
**Then** the nested worker receives a wrapper importing the same shim before
`inner.js`
**And** `'__wsShimUrl' in globalThis` is `false`

#### Scenario: A module worker spawning a worker propagates the shim

Regression: module wrappers once set `__wsShimUrl` by assignment, which hoisting
placed after the shim import, so module workers left `Worker` unpatched. They
were spoofed themselves, but anything they spawned reported the real hardware —
`new Worker(x, {type:'module'})` then `new Worker(y)` read straight through.

**Given** the shim payload is running in a module worker
**Then** `globalThis.__ws_worker_shim__` is `true`
**When** that worker calls `new Worker('inner.js')`
**Then** the nested worker reports the same spoofed values as the document

---

### Requirement: WORK-007 - The real constructor is unreachable after the patch

A wrapper that takes the real constructor's prototype object
(`Patched.prototype = Real.prototype`) inherits that object's own `constructor`
property, which still points at the real constructor. `Worker.prototype.constructor`
is then the unpatched `Worker`, and two lines of page script open a realm the
payload never reaches. The patch SHALL therefore re-point `constructor` at the
wrapper after taking the prototype, and SHALL do so inside the shared installer
definition so a nested (worker-spawned) install is covered on the same terms as
the page install.

Re-pointing SHALL be individually guarded: a frozen or non-configurable
prototype must not abort the rest of the patch, and must not throw out of the
concatenated-IIFE payload where an uncaught error silences every later shim.

#### Scenario: A worker built through the prototype constructor is still shimmed

**Given** a site with an active per-site shim
**When** the page calls `new (Worker.prototype.constructor)('probe.js')`
**Then** the real constructor receives a `blob:` wrapper URL, not `'probe.js'`
**And** the worker reports the same `hardwareConcurrency`, `deviceMemory`,
`languages`, `userAgent` and `Intl.DateTimeFormat().resolvedOptions().timeZone`
as the document (WORK-002)
**And** the same holds for `SharedWorker.prototype.constructor`

#### Scenario: A worker spawned by a worker inherits the re-point

**Given** a worker created through the patched constructor
**When** that worker calls `new (Worker.prototype.constructor)('nested.js')`
**Then** the nested worker is wrapped exactly as WORK-005 requires of a direct
`new Worker` call

---

### Requirement: WORK-006 - Fail open, and only where it helps

The patch SHALL be installed only when at least one shim is active, so a site
with no spoofing keeps the stock constructors and cannot be broken by the blob
indirection. When wrapping throws, the original script SHALL be passed to the
real constructor verbatim: a broken worker is worse than an unspoofed one.

A CSP whose `worker-src` (or the `child-src`/`script-src`/`default-src` it falls
back to) omits `blob:` refuses every wrapper, and chromium reports that refusal
as an asynchronous `error` event on the worker rather than a constructor throw,
so the fallback above never sees it and the site is left with a worker that
never starts.

The installer SHALL NOT test the policy in advance. A page cannot read one —
a header-delivered CSP is invisible to JS, and the only time the platform hands
a page its own policy is inside a violation report — so testing means breaking
the policy, and doing that at document start breaks it on every load of every
refusing site whether or not the page had any use for a worker. That is
first-party observable (a `securitypolicyviolation` listener sees it, a
`report-uri` mails it home) and nothing in a stock browser does it, so it
announces the app. Instead the site's own first worker SHALL be what finds out:
it is wrapped, and its refusal is the answer. Once a refusal is known, wrapping
stops and every later worker receives the page's own script, unshimmed but
alive. The worker that found out is not lost either (see WORK-008).

When a violation report reaches the document first, for whatever reason, the
installer SHALL read `originalPolicy` and answer from the policy itself rather
than from the refusal in front of it, resolving the question without having
caused anything. A report-only policy blocks nothing and SHALL NOT be read as a
refusal.

Where no policy text is available, only a `blob:` refusal under a directive that
governs worker scripts SHALL count. Chromium names the *effective* directive, so
a policy that reaches workers through `script-src` still reports `worker-src`;
a refused `blob:` *script* stays a script refusal and SHALL leave the wrapping
alone, so a site that admits `blob:` workers while refusing `blob:` scripts
keeps its workers shimmed.

The payload SHALL NOT ask anything in worker scope: a worker running it is
itself proof that its document admits `blob:` workers.

In the classic wrapper the shim's `importScripts` SHALL be caught and the
original's SHALL NOT, so a CSP that admits the wrapper but refuses what it
imports also costs the spoof rather than the worker.

#### Scenario: No shims, no patch

**Given** a site with no active per-site shim
**Then** no worker installer script is injected

#### Scenario: A document that builds no worker never touches the CSP

**Given** a page whose `worker-src` omits `blob:`
**When** the page never constructs a worker
**Then** the document records no CSP violation at all

#### Scenario: Wrapping failure still yields a working but unshimmed worker

**Given** `URL.createObjectURL` throws, or the engine refuses a `blob:` worker at
construction time
**When** the page calls `new Worker('w.js')`
**Then** the real constructor receives `'w.js'` unchanged
**And** a worker is still created
**And** that worker is NOT shimmed — it reports the machine's real values while
the document reports the spoofed ones

#### Scenario: A blob-less CSP costs the shim, not the site's workers

Regression: messenger.com sets `worker-src` without `blob:`. Every wrapper was
refused asynchronously, so no fallback ran and no worker started — the chat
worker died and "verifying your PIN" hung with no error and no timeout.

**Given** a page whose `worker-src` omits `blob:`
**When** the page calls `new Worker('w.js')`, classic or module, and then builds
a second worker
**Then** both workers run
**And** the second is handed its own script, never a wrapper
**And** the document records exactly one violation, for the wrapper the first
worker was given

#### Scenario: The fallback directive answers too

**Given** a page that sets `script-src` without `blob:` and sets neither
`worker-src` nor `default-src`
**When** the page builds a worker
**Then** it runs unshimmed
**And** the recorded violation names the effective directive `worker-src`, not
the `script-src` the console message attributes the refusal to

#### Scenario: An unrelated blob: refusal says nothing about workers

**Given** a page that admits `blob:` workers and refuses `blob:` images
**When** the site's own blob image is refused
**Then** the policy is read off that report
**And** the page's workers are still wrapped and shimmed

#### Scenario: A refused shim import does not take the worker with it

**Given** a CSP admitting `blob:` workers but not `blob:` scripts
**When** the wrapper's `importScripts` of the shim payload is refused
**Then** the original script is still imported and the worker runs unshimmed

Every branch above is the same trade, not an implementation defect, and the cost
MUST be read as such: an unshimmed worker is a live `WORK-002` disagreement, and
a fingerprinter reads the real hardware there while the document reports the
spoof. It is taken only where the alternative is a worker that never starts, and
only for the document that proved it. All branches are pinned by
`test/browser/worker_realm_escape.test.js`, against a page whose CSP is the one
messenger.com sends.

---

### Requirement: WORK-008 - The worker that finds the refusal is not lost

The refusal reaches the worker that carried the wrapper, asynchronously, after
its constructor returned: WORK-006's fail-open branch cannot see it, and the
page is left holding a worker that never starts. Every wrapper handed out before
the answer is known SHALL therefore be recoverable.

For a dedicated `Worker`, the installer SHALL keep what rebuilding it takes —
the real constructor, the page's own script argument and options, and the
messages posted to it — and on a refusal SHALL construct that worker on the
page's own script and route it through the object the page already holds:
`postMessage` and `terminate` forwarded to the rebuilt worker, its `message`,
`messageerror` and `error` events re-dispatched on the original object, and the
recorded messages replayed in order. Handing the page a second object cannot do
this: its handlers, its `instanceof`, and every reference it passed on belong to
the one it has.

A `SharedWorker` cannot be swapped that way, because the page takes its
`MessagePort` at construction and a port cannot be re-entangled with a second
worker. The installer SHALL therefore hand the page one end of a `MessageChannel`
of its own in place of that port, forward both directions, and on a refusal
re-point its own end at the rebuilt worker's port.

Messages SHALL be recorded rather than withheld: holding a page's messages until
the answer arrives would delay the workers of every site to serve the refused
one. The record SHALL be bounded, since a refusal always lands within a task or
two of construction. A transferable is detached by the post that went to the
refused wrapper and is lost to the replay, which is the narrower cost.

Anything a wrapped worker says is proof that its wrapper ran, and SHALL settle
the question for the document. The refused wrapper's own `error` SHALL NOT reach
the page — it belongs to a worker the page never had — and an `error` carrying a
message SHALL be left alone: a refusal never reaches any script, so only a
message-less error can be one, and rebuilding on the site's own runtime error
would run its worker twice. Once `blob:` workers are known to run, the rescue
SHALL stop intercepting errors at all: a message-less error there is the site's
own script failing to load, and swallowing it would hide a real breakage.

#### Scenario: The worker that finds the refusal still runs

**Given** a page whose `worker-src` omits `blob:`
**When** an inline script at the top of the document calls `new Worker('w.js')`
and posts a message to it
**Then** the worker runs and answers that message
**And** the page's `onerror` is never called for the wrapper the CSP refused
**And** the worker is NOT shimmed — the WORK-006 trade

#### Scenario: PREMISE - that worker really is wrapped

**Given** the same inline script on a page whose CSP admits `blob:` workers
**Then** its worker runs and IS shimmed, reporting the document's own
`hardwareConcurrency`

#### Scenario: A SharedWorker survives the refusal

**Given** a page whose `worker-src` omits `blob:`
**When** the page calls `new SharedWorker('s.js')` and posts through `port`
**Then** the worker runs and answers on that same port
**And** it is NOT shimmed
**And** the same call on a page admitting `blob:` workers is shimmed

#### Scenario: An error from the site's own worker is not read as a refusal

**Given** a wrapped worker whose own script throws
**When** the resulting `error` event carries a message
**Then** the page's handler receives it
**And** nothing is rebuilt

#### Scenario: After the answer, a failed load still reaches the page

**Given** a wrapped worker that has already sent the page a message
**When** it later fires a message-less `error` — its script failed to load
**Then** the page's handler receives it
**And** nothing is rebuilt

---

## Limitations

- **CSP forbidding `blob:` workers.** No wrapper can preload the shim past such
  a policy, so those workers run unshimmed.
- **The first worker of a refusing document pays for the answer.** It is
  rebuilt, so it runs, but it runs unshimmed and it costs the one CSP violation
  that tells the installer what the policy says. Only a policy read natively,
  off the response headers, could answer without it, and the platform that would
  have to supply them (Android's WebView) exposes response headers only for
  status >= 400.
- **Nested module workers.** Module workers receive the shim, but not the
  nested-propagation tail — `import.meta` cannot appear in the classic payload,
  so a module worker cannot learn its own URL.
- **Service workers.** Out of reach: `ServiceWorkerContainer.register()` rejects
  `blob:` script URLs.
- **Non-JS-observable axes.** Engine math ULPs, API-shape key counts, and
  system-font tells identify the real engine in a worker exactly as they do on
  the page; no shim addresses those (see `tracking-protection`).

---

## Files

- `lib/services/worker_shim.dart` — `buildWorkerShimScript`, the installer JS
- `lib/services/webview.dart` — collects `workerScopeShims` in injection order
  and registers the `worker_shim` `UserScript`
- `lib/services/{language_shim,user_agent_identity_shim,anti_fingerprinting_shim,location_spoof_service}.dart`
  — scope-agnostic shim sources
- `test/worker_shim_test.dart` — builder tests plus the structural gate that
  fails if a payload shim dereferences `window`
- `test/js/shim_prototype_constructor.test.js` — class-level gate (WORK-007 /
  BUG-009): a new `X.prototype = Y.prototype` in any shim source fails CI unless
  `constructor` is re-pointed next to it
- `test/js/worker_shim.test.js` — installer tests under jsdom, and the payload
  executed in a simulated `WorkerGlobalScope` via `node:vm`
- `test/browser/worker_realm_escape.test.js` — realm coverage, the CSP
  branches, and the WORK-008 window under a real engine
