# Webview Downloads

## Status
**Implemented**

## Purpose

Lets the user save files initiated by a webview. The underlying
`flutter_inappwebview` exposes `onDownloadStartRequest`, but the host app
must enable the setting, fetch/decode the bytes, run a save dialog, and
surface progress. This spec covers the three common schemes (`http(s)`,
`data:`, `blob:`) plus the in-app progress UI.

## Problem Statement

Before this spec:

1. `useOnDownloadStart` defaulted to false, so `onDownloadStartRequest`
   never fired and webview-triggered downloads silently dropped.
2. Android also required a `FileProvider` declaration with authority
   `${applicationId}.flutter_inappwebview_android.fileprovider` for the
   upload-side `<input type=file>` camera/video path; without it the
   file chooser threw `IllegalArgumentException`.
3. For `blob:` URLs, the download URL is a JS-heap reference —
   un-fetchable from Dart. A browser-side shim is required to read the
   blob and hand the bytes to Dart.
4. Even after a successful download, the main-frame navigation to the
   download URL left the webview on a `net::ERR_UNKNOWN_URL_SCHEME`
   page.

## Solution

### Upload (file chooser)

`android/app/src/main/AndroidManifest.xml` declares a `FileProvider`
with authority `${applicationId}.flutter_inappwebview_android.fileprovider`,
pointing at
`android/app/src/main/res/xml/flutter_inappwebview_android_provider_paths.xml`
which whitelists `files/`, `cache/`, and the external equivalents so the
plugin can build content URIs for camera/video temp files.

### Download

Three code layers:

1. **Logic engine** — [`DownloadEngine`](../../../lib/services/download_engine.dart)
   (pure Dart + injectable `http.Client`).
   - `fetch(url, cookieHeader?, userAgent?, suggestedFilename?, mimeTypeHint?, onProgress?)`
     — issues a streamed `GET`, accumulates chunks, reports per-chunk
     progress; throws `DownloadException` on non-2xx / network error /
     unsupported scheme.
   - `decodeDataUri(url, suggestedFilename?)` — parses `data:` URIs via
     `UriData`, returns bytes + mime + derived filename.
   - `fromBase64(base64Data, suggestedFilename?, mimeType?)` — wraps a
     base64 payload from the blob JS shim into a `DownloadResult`.
   - `deriveFilename(...)` — sanitized filename from suggestion → URL
     path segment → MIME-based fallback.

2. **Render engine** —
   [`WebViewFactory`](../../../lib/services/webview.dart)
   wires `useOnDownloadStart: true` into the shared
   `InAppWebViewSettings` and dispatches in
   `_handleDownloadRequest` based on scheme.
   - `http`/`https`: call `DownloadEngine.fetch`, stream progress into
     `DownloadsService`.
   - `data:`: synchronous decode, save via picker.
   - `blob:`: register `_webspaceBlobDownload` /
     `_webspaceBlobDownloadError` JS handlers once in
     `onWebViewCreated`; kick off an IIFE via `evaluateJavascript` that
     does `fetch(blobUrl) → Blob → FileReader.readAsDataURL → callHandler`.

3. **UI** — [`DownloadsService`](../../../lib/services/download_manager.dart)
   (singleton `ChangeNotifier` holding `List<DownloadTask>`),
   rendered by [`DownloadButton`](../../../lib/widgets/download_button.dart)
   in both the root app bar and the nested
   [`InAppWebViewScreen`](../../../lib/screens/inappbrowser.dart) bar.

## Requirements

### Requirement: DL-001 — FileProvider for the file chooser

The Android manifest MUST declare a `FileProvider` with authority
`${applicationId}.flutter_inappwebview_android.fileprovider` and a
`FILE_PROVIDER_PATHS` resource covering `files/`, `cache/`, and the
external equivalents.

#### Scenario: User taps an `<input type=file>` control that opens the camera
**Given** the app is installed on Android
**When** the webview invokes `InAppWebViewChromeClient.getOutputUri`
**Then** `FileProvider.getUriForFile` finds the meta-data
**And** the camera/video intent receives a valid content URI

---

### Requirement: DL-002 — Webview download callback enabled

`useOnDownloadStart` MUST be set to `true` on the shared
`InAppWebViewSettings` so `onDownloadStartRequest` fires for responses
the webview decides to download.

#### Scenario: Server returns `Content-Disposition: attachment`
**Given** the user clicks a link whose response carries
  `Content-Disposition: attachment`
**When** the webview receives the response
**Then** `onDownloadStartRequest` fires in both the root webview and
  any nested `InAppWebViewScreen`
**And** `controller.stopLoading()` is called so the main frame does
  not render the response as a page

---

### Requirement: DL-003 — HTTP(S) downloads

`DownloadEngine.fetch` MUST stream the body via `http.Client.send`,
forwarding the webview's cookies (resolved via
`CookieManager.getCookies(url:)`) and the request's `userAgent` so
authenticated downloads succeed.

#### Scenario: Authenticated download
**Given** the user is logged in to a site whose download URL requires
  session cookies
**When** the download starts
**Then** the `Cookie:` header is built from `CookieManager.getCookies(url:)`
  and forwarded on the `GET`
**And** the response body is saved via `FilePicker.saveFile` with the
  header-derived (or URL-derived) filename

#### Scenario: Server error
**Given** the download URL returns 4xx/5xx
**When** `fetch` completes
**Then** a `DownloadException` with the status code is thrown
**And** the corresponding `DownloadTask` transitions to
  `DownloadState.failed` with the error message

---

### Requirement: DL-004 — `data:` URI downloads

`DownloadEngine.decodeDataUri` MUST handle both base64 (`;base64,`) and
URL-encoded forms, with or without an explicit mime (RFC 2397 default
of `text/plain` when absent is surfaced unchanged).

#### Scenario: Base64 data URI
**Given** a link with `href="data:application/pdf;base64,..."` triggers
  a download
**When** `_handleDownloadRequest` runs
**Then** the payload is decoded in Dart without a webview round-trip
**And** the user sees a save dialog with a filename derived from the mime

---

### Requirement: DL-005 — `blob:` URI downloads

Blob URLs MUST be read via an injected JS IIFE that hands the base64
payload to a registered `JavaScriptHandler` named
`_webspaceBlobDownload`. Errors MUST be reported via
`_webspaceBlobDownloadError`. The `taskId` MUST be round-tripped
through JS so the Dart handler can resolve the originating task.

The IIFE MUST first try a side-channel lookup against the Blob captured
by the `blob_url_capture` DOCUMENT_START shim
([`lib/services/blob_url_capture.dart`](../../../lib/services/blob_url_capture.dart)),
which wraps `URL.createObjectURL` and stores every minted Blob in a
bounded map exposed as `window.__webspaceBlobs.get(url)`. Only when the
URL is absent from that map (e.g. minted in a worker realm) MAY the IIFE
fall back to `fetch(blobUrl) → Blob → FileReader.readAsDataURL`. The
captured-Blob path is required because sites with strict CSP
`connect-src` (e.g. github.com) reject `fetch(blob:…)` even when the
blob is same-origin — the WebView enforces the directive where stock
Chrome/Firefox internally exempt blob reads — and a fetch-only
implementation silently breaks downloads on those sites.

#### Scenario: Pairdrop WebRTC file transfer
**Given** pairdrop.net produces an in-memory `Blob` and triggers a
  download via `<a download href="blob:...">`
**When** `onDownloadStartRequest` fires with scheme `blob`
**Then** the IIFE reads the blob, ships base64 back over the handler,
  and Dart saves the decoded bytes via `FilePicker.saveFile`
**And** the `DownloadTask` completes with the resolved file path

#### Scenario: GitHub blob download under strict CSP
**Given** the user clicks a link on github.com that triggers a download
  of a `blob:https://github.com/…` URL minted by a same-origin call to
  `URL.createObjectURL`
**And** github.com's response `Content-Security-Policy` does not
  whitelist `blob:` for `connect-src`
**When** `onDownloadStartRequest` fires with scheme `blob`
**Then** the IIFE looks the URL up in `window.__webspaceBlobs`, finds
  the captured `Blob`, and reads it via `FileReader.readAsDataURL`
  without invoking `fetch`
**And** the `DownloadTask` completes successfully without producing a
  CSP `connect-src` violation in the WebView console

---

### Requirement: DL-006 — In-app progress UI

`DownloadsService` MUST expose the list of active and recently-finished
tasks as a `ChangeNotifier`. A `DownloadButton` MUST live in the app
bar of both `_WebSpacePageState` and `InAppWebViewScreen`, showing a
spinning ring (determinate when `Content-Length` is known, indeterminate
otherwise) while any task is active, and rendering nothing when the
task list is empty.

#### Scenario: Concurrent downloads
**Given** two HTTP downloads are in flight
**When** progress callbacks fire
**Then** the app-bar icon shows an aggregate progress ratio across both
**And** tapping the icon opens a bottom sheet listing each task with
  its own progress bar, bytes done/total, and filename

#### Scenario: Download completes
**Given** a download finishes successfully
**When** the save dialog resolves with a path
**Then** the `DownloadTask` transitions to `DownloadState.completed`
  with `savedPath` populated
**And** the app-bar icon switches to the `download_done` glyph
**And** the task stays in the list until `Clear finished` is tapped or
  the task is dismissed

---

## Implementation

### Files

- `lib/services/download_engine.dart` — pure-Dart fetch/decode/filename logic.
- `lib/services/download_manager.dart` — `DownloadsService` +
  `DownloadTask`.
- `lib/services/webview.dart` — wires settings, JS handlers, and
  `_handleDownloadRequest` (HTTP/data/blob dispatch, `stopLoading()`
  guard).
- `lib/services/blob_url_capture.dart` — DOCUMENT_START shim wrapping
  `URL.createObjectURL` / `URL.revokeObjectURL` so the blob-download
  IIFE can read CSP-restricted blobs without calling `fetch()`.
- `lib/widgets/download_button.dart` — app-bar action + bottom sheet.
- `lib/main.dart`, `lib/screens/inappbrowser.dart` — place the button.
- `android/app/src/main/AndroidManifest.xml` —
  `FileProvider` declaration.
- `android/app/src/main/res/xml/flutter_inappwebview_android_provider_paths.xml`
  — paths resource.

### Tests

- `test/download_engine_test.dart` — cookie/UA forwarding, filename
  derivation + sanitization, scheme rejection, status/network-error
  mapping, `data:` + base64 decoding, streamed progress with and
  without `Content-Length`.
- `test/download_manager_test.dart` — task lifecycle (start /
  updateProgress / complete / fail / cancel / dismiss / clearCompleted),
  listener notification, unknown-id no-ops.
- `test/blob_url_capture_test.dart` — Dart-side string assertions for
  the shim and `buildBlobDownloadIife`: shim reentrance guard,
  createObjectURL/revokeObjectURL wrap pair, instanceof Blob filter,
  non-enumerable export, MAX=64 bound, registration in
  WebViewFactory at AT_DOCUMENT_START, IIFE references the shim's
  global, JSON-escaped substitution of inputs, both branches present,
  handler argument shapes.
- `test/js/blob_url_capture_shim.test.js` — jsdom behavioural test for
  the createObjectURL wrapper: roundtrip Blob lookup, revoke clears the
  entry, non-Blob arguments are not tracked, idempotent re-eval, MAX=64
  bound evicts oldest, `__webspaceBlobs` is non-enumerable.
- `test/js/blob_download_iife.test.js` — jsdom behavioural test for the
  IIFE's branch selection: fast path reads captured Blob and avoids
  fetch entirely, fallback calls fetch and routes the result through
  the same FileReader path, fetch rejection routes through the error
  handler with the original message, synchronous throws on the fast
  path also reach the error handler.
- `test/browser/blob_url_capture_csp.test.js` — Puppeteer test that
  boots a headless Chromium against a tiny HTTP server serving
  `Content-Security-Policy: connect-src 'none'`. Two scenarios:
  (1) PREMISE — without the shim, fetch(blob:) is rejected by the
  browser's CSP enforcer (proven via a `securitypolicyviolation`
  event), and the IIFE reports the error; (2) FIX — with the shim
  installed at DOCUMENT_START via Puppeteer's `evaluateOnNewDocument`,
  the IIFE finds the captured Blob, never invokes fetch, and reports
  success with the right base64 / mime / taskId. Auto-skips when
  Puppeteer can't launch Chromium; opt-in via
  `WEBSPACE_RUN_BROWSER_TESTS=1 ./scripts/test_all.sh` or
  `npm run test:browser`.

### Manual verification

1. **Upload** — open a webview, tap an `<input type=file>` that offers
   camera, confirm no `IllegalArgumentException` in logcat and the
   camera intent opens.
2. **HTTP** — open a site with a real download link (e.g. a GitHub
   release `.apk`). Expect a progress ring in the top-right, a save
   dialog, and `Saved <file>` in the downloads sheet when done.
3. **Data URI** — trigger a `data:` download (e.g. a small PNG
   generated by a canvas). Expect instant save dialog.
4. **Blob** — pairdrop.net: receive a file. Expect progress + save
   dialog + the downloads sheet showing the completed task.
5. **Blob (CSP-restricted)** — open a github.com PR, trigger an attachment
   download (e.g. "Download" on a CI run artifact, or any `<a download>`
   pointing at a `blob:https://github.com/…` URL). Expect the same
   progress + save dialog as pairdrop, with no
   `Refused to connect because it violates the document's Content
   Security Policy` line in the WebView console.

## Caveats / Known Limits

- Blob `evaluateJavascript` runs in the top frame only. A blob created
  inside a cross-origin iframe cannot be fetched from the top frame;
  the shim surfaces a `TypeError` via `_webspaceBlobDownloadError`.
- The `blob_url_capture` shim only sees Blobs minted by main-thread
  `URL.createObjectURL` calls in the top frame. A Blob minted in a
  Worker (and surfaced to the main thread only as a URL string) is
  absent from `window.__webspaceBlobs`; the IIFE falls back to
  `fetch(blobUrl)`, which still fails on hosts whose CSP `connect-src`
  forbids `blob:`. No known consumer hits this corner case in
  practice — the GitHub flow that motivated the shim mints the Blob in
  the main thread.
- The base64 round-trip buffers the whole payload in memory (plus ~33%
  base64 overhead). Multi-GB blob downloads will OOM; streaming is out
  of scope.
- `DownloadStartRequest.suggestedFilename` is often empty for
  blob:-backed `<a download>` clicks on Android (Android WebView does
  not parse the `download` attribute in `DownloadListener`). The engine
  falls through to a mime-based `download.<ext>` fallback; the user can
  rename in the save dialog.
- Download history is in-memory and resets on app restart (matches the
  behavior the user signed off on — no persisted stats).
