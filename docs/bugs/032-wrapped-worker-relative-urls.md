# BUG-032 — A wrapped worker resolves its relative URLs against a blob:

Status: **open, fix in review.** Every loader a worker script commonly uses is
covered; the ones in gap 1 are not.

**Spec:** [worker-shim-propagation](../../openspec/specs/worker-shim-propagation/spec.md)
WORK-009 (WORK-001 for the constructor's own specifier)
**Related:** [BUG-009](009-shim-realm-escape.md), the same wrapper seen from the
fingerprinting side

## Symptom

On a site with any per-site shim that reaches workers (Tracking Protection, a
custom User-Agent, language or time zone), a worker whose script loads anything
by a relative URL fails. In WebKit, `importScripts('lib.js')` throws
`SyntaxError: The string did not match the expected pattern`; in Chromium,
`fetch('data.json')` rejects with `TypeError` and `new Request('data.json')`
throws. A webpack worker fails to load its chunks: its automatic `publicPath`
is read off `self.location`, which reports the wrapper's `blob:` URL.

## Root mechanism

The worker shim replaces the page's script with a generated `blob:` wrapper
that imports the shim payload and then the original script. The blob becomes
the worker's own URL and the base every relative URL resolves against, and a
`blob:` URL has no path to resolve against. Whatever the site's script loads
after its own first line inherits that base.

**Invariant:** a wrapped worker reports, and resolves against, the URL of the
script the page asked for.

## Fix attempts

1. **2026-07-31, bbc63f9 (#519).** *What:* the worker shim resolves the
   constructor's specifier to an absolute URL before baking it into the
   wrapper's `importScripts` (WORK-001). *Why:* `importScripts('w.js')` inside
   a blob worker would resolve against the blob and fail. *Why partial:* it
   covered the one URL the wrapper itself loads. Every URL the site's script
   then loads, and the `self.location` it reads, still carried the blob. The
   browser tier passed absolute leaf URLs to nested workers rather than asking
   why relative ones failed.
2. **2026-10-13, branch `fix/worker-relative-urls`.** *What:* the wrapper runs
   `rebaseWorker` (`lib/js/_worker_installer.js`) before anything else loads:
   `WorkerLocation` reports the original URL, and `importScripts`, `fetch`,
   `Request`, `XMLHttpRequest.prototype.open`, `Worker` and `SharedWorker`
   resolve a relative argument against it. It travels in the wrapper as
   source, so a CSP that refuses the shim's import still keeps it, and the
   payload disguises what it replaced. `test/browser/worker_base_url.test.js`
   runs each worker kind wrapped and unwrapped and requires the two to agree.
   *Why:* the wrapper is the one place that knows both URLs, so the fix owns
   the base for every loader at once rather than each call site. *Why
   partial:* the loaders in gap 1.

## Known open gaps

1. `EventSource`, `WebSocket`, `Response.redirect` and Cache API keys still
   resolve against the blob.
2. Not this bug, found beside it: `asNative` writes V8's one-line
   `function f() { [native code] }`, while JavaScriptCore prints
   `function f() {\n    [native code]\n}` and names a getter without `get `, so
   on iOS and macOS every shim's disguise reads differently from the engine's
   own. The disguise test in `worker_base_url.test.js` fails on WebKit for
   this reason alone.
