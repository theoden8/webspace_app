# BUG-017 — A file import's synthetic URL reaches the engine as a load

Status: **open, narrowed.** Every load and reload the model issues now goes
through one seam that renders the import instead of fetching its URL. Raw
native loads inside `WebViewFactory` itself still bypass that seam (see open
gaps).

**Spec:** [file-import-sites](../../openspec/specs/file-import-sites/spec.md)
IMPORT-003, IMPORT-005; [navigation](../../openspec/specs/navigation/spec.md)
NAV-006.
**Tests:** `test/file_import_sites_test.dart`,
`test/js/file_import_synthetic_url_funnel.test.js` (structural gate).

## Symptom

An imported HTML file, which rendered fine, turns into an error or a load that
never ends. Reported forms: `ERR_INVALID_URL` / `ERR_FILE_NOT_FOUND` in place of
the page; on iOS, pull-to-refresh spinning forever with the loading bar stuck
and the action button stuck on Stop.

## Root mechanism / invariant

An import is rendered from stored bytes (`HtmlImportStorage`) as substitute
data under a synthetic `file:///<filename>` URL. Nothing exists at that URL. Any
path that asks the engine to *fetch* it fails, and each engine fails
differently:

- Chromium: `loadUrl(file:///x.html)` commits an `ERR_FILE_NOT_FOUND` error page
  (`allowFileAccess` is on, so it looks for `/x.html`). Its `reload()` is safe:
  the navigation entry keeps the data URL and the base URL, so the bytes are
  reloaded.
- WebKit (iOS, macOS, Linux WPE): `reload()` is not safe. `FrameLoader::reload`
  builds the new request from the document loader's URL, which for a
  `load(_:mimeType:characterEncodingName:baseURL:)` page is the base URL, and
  `defaultSubstituteDataForURL` only restores `about:srcdoc`. So a reload
  fetches `file:///x.html`, fails provisionally, and the plugin reports that
  through `onReceivedError` alone. `onLoadStop` is what ends the
  pull-to-refresh indicator and clears `isLoading`, so neither ends.

Invariant: **the engine is never asked to fetch a file import's URL.** Every
instance below is a path that did.

## Fix attempts

1. **2026-04-30 — [#267](https://github.com/theoden8/webspace_app/pull/267)
   `b492dbc`.** Emit `file:///<name>` instead of `file://<name>` (the two-slash
   form parsed the filename as a host and Chromium rejected it as
   `ERR_INVALID_URL`), migrate legacy URLs, and render
   `buildFileImportFallbackHtml` through `initialData` when the import bytes
   are missing instead of loading the URL. *Why*: the missing-bytes case
   (incognito, the upgrade wipe) fell through to `initialUrlRequest`, a direct
   load of the synthetic URL. *Why partial*: covered the webview's first
   document only. Every later load or reload of an existing webview still
   targeted the URL.

2. **2026-06-26 — [#448](https://github.com/theoden8/webspace_app/pull/448)
   `e106ae5`.** `deferInitialLoadForRestore` excludes file imports, so the
   Android back/forward restore does not suppress `initialData` and then reload
   or load the synthetic URL from `onControllerCreated`. *Why*: the
   post-restore reload would surface `ERR_FILE_NOT_FOUND`, and a static page
   has no history worth restoring. *Why partial*: a per-path exclusion. When
   the proxy deferral (`deferInitialLoadForProxy`, LEAK-003) landed on
   2026-09-10 in [#593](https://github.com/theoden8/webspace_app/pull/593)
   (`db47ddd`) it carried no such exclusion, so an import built while the
   Android/Linux proxy override was active had its first document issued by
   `setController` as `loadUrl(currentUrl)`. The WebKit reload was never
   covered.

3. **2026-09-24 — this branch.** Moved the rule to the controller wrapper.
   `WebViewFactory.createWebView` builds a `FileImportDocument` (the stored
   import, or the fallback page) for an import and hands it to
   `_WebViewController`. `loadUrl` of the import's URL (fragment ignored)
   renders the document. `reload()` renders it on WebKit and stays native on
   Chromium, where re-rendering would add a history entry per refresh. *Why*:
   model code (pull-to-refresh, the Refresh button, Clear-cookies, the
   notification refresh, the proxy-deferred first load, the PAUSE-022 resume
   reissue) reaches the engine only through `WebViewController`, so one
   check there covers every existing path and any new one. The structural gate
   fails CI if the wrapper stops checking, if the wrapper given to the model
   loses the document, or if model code calls `nativeController` loads
   directly. *Why partial*: see open gaps.

## Known open gaps

- **Raw native loads inside `WebViewFactory`.** The factory holds the raw
  `inapp.InAppWebViewController` and calls `controller.reload()` /
  `controller.loadUrl()` on it in its own recovery paths, which the wrapper
  never sees. The TLS-pin retry after `_promptUntrustedCertificate` reloads
  natively; on WebKit that is this bug again if an import's page reaches that
  prompt. The external-scheme fallback in `onReceivedError` loads
  `lastStableUrl ?? config.initialUrl`, but only when no `onExternalSchemeUrl`
  host hook is set, which the root site webview always sets.
- **Failed main-frame loads on WebKit never end the loading UI, whatever the
  URL.** This is a separate defect, not an instance of this bug: an offline
  pull-to-refresh on an ordinary site fails through `onReceivedError` with no
  `onLoadStop`, so the indicator and `isLoading` stay on. Tracked here because
  it produced this bug's iOS symptom.
- **In-page `file:` links.** A relative link in an import resolves to
  another `file:///` URL and navigates natively. It fails the way it would in
  any browser, since the other file was never imported. Not intercepted.
