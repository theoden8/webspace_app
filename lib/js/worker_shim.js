// Worker / SharedWorker shim propagation.
//
// Every per-site JS shim (language, UA identity, timezone, anti-fingerprinting)
// is injected as a `UserScript` into the *document*. A `Worker` or
// `SharedWorker` runs in a separate global scope that no UserScript reaches, so
// a page that re-reads the same values inside a worker sees the real OS/engine
// values instead of the spoofed ones. That is not a partial leak but a total
// bypass, and a deliberate one: CreepJS re-reads locale, timezone, UA, cores
// and GPU inside a worker precisely to defeat main-thread-only spoofing, then
// reports the page/worker disagreement as its strongest signal.
//
// Mechanism: patch the `Worker` / `SharedWorker` constructors so the script URL
// the page asked for is replaced by a generated `blob:` script that first loads
// the shim payload, then the original script:
//
//     importScripts(<shim blob>); importScripts(<original url>);
//
// Both loads are synchronous and ordered, so the shims are installed before a
// single line of the site's worker code runs — the worker-scope equivalent of
// `AT_DOCUMENT_START`. A blob worker inherits the creating document's origin,
// and classic worker scripts are same-origin by spec, so `importScripts` of the
// original URL is always permitted.
//
// The payload is the SAME shim source the page gets, which is the point: a
// worker reporting a different `hardwareConcurrency` than its page would be a
// fresh fingerprint. The shims are scope-agnostic (`globalThis`, navigator
// prototype resolved from the live `navigator`, window-only sections guarded),
// so one source serves both scopes.
//
// A CSP whose `worker-src` omits `blob:` refuses the wrapper, and chromium
// reports that refusal as an asynchronous `error` event on the worker rather
// than a constructor throw — so the fail-open branch below never sees it and
// the site is left with a worker that never starts (messenger.com: the chat
// worker dies and "verifying your PIN" hangs forever).
//
// A page cannot read the policy that would say so in advance. A header-
// delivered CSP is invisible to JS, and the one time the platform hands a page
// its own policy is inside a violation report — from in here, the only way to
// learn the rule is to break it. So nothing is asked in advance: the site's
// first worker is the test. It gets a wrapper, and if the CSP refuses it the
// worker is rebuilt on the site's own script behind the object the page
// already holds, which the page cannot tell apart from the worker it asked
// for. That refusal is the answer, and every worker after it is handed its
// original script — unshimmed, but alive.
//
// So a document that never builds a worker never touches the CSP, where asking
// up front announced the app to every site on every load. When the site
// happens to break its own policy first for unrelated reasons, the report
// carries `originalPolicy` and the same answer is read out of it for free.
//
// Known limits, all fail-open (functionality preferred over an extra spoof):
//   * Under such a CSP the workers run unshimmed, which is a live page/worker
//     disagreement (WORK-002) — the trade WORK-006 makes rather than leaving
//     the site with workers that do not start.
//   * The first worker of a refusing document is the one that pays for the
//     answer: it is rebuilt, so it runs, but it costs one CSP violation.
//   * Module workers (`{type:'module'}`) get the shim via ordered static
//     `import`s, but no nested propagation (`import.meta` cannot appear in the
//     classic payload).
//   * Service workers are out of reach: registration rejects `blob:` scripts.
//
// This is the page-side installer; CONFIG.payload is what every worker loads
// first: the page's own scoped shims followed by worker_payload.js.
(function() {
  'use strict';
  // @include _native_fn.js
  // @include _worker_installer.js
  var PAYLOAD = CONFIG.payload;
  var _url = null;
  __wsInstallWorkerWrap(function() {
    if (_url === null) {
      _url = URL.createObjectURL(new Blob([PAYLOAD], { type: 'text/javascript' }));
    }
    return _url;
  }, true);
})();
