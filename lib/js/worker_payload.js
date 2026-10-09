// The tail of the payload every worker loads after the page's shims: it
// re-installs the same patch inside the worker, so a worker spawning a worker
// stays covered. It reads its own blob URL from `__wsShimUrl`, which the
// generated wrapper assigns before importing it (a script cannot otherwise
// learn the URL it was loaded from).
(function() {
  // @include _native_fn.js
  // @include _worker_installer.js
  try {
    var u = globalThis.__wsShimUrl;
    try { delete globalThis.__wsShimUrl; } catch (e) {}
    if (u) __wsInstallWorkerWrap(function() { return u; }, false);
  } catch (e) {}
})();
