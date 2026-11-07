# SEC-045 remediation: platform-sourced frame identity for the JS bridge

The implementable fix for SEC-045 ([2026-11-07-review.md](2026-11-07-review.md)).
It belongs in `theoden8/flutter_inappwebview` plus the app's handler wiring. This
spec is exact enough to build and test; it has not been built or tested in the
session that wrote it, so it is a plan, not a verified fix.

## The invariant to establish

> The `origin` and `isMainFrame` a bridge handler acts on come from the engine,
> never from the page.

Today that holds on iOS and macOS (`message.frameInfo`) and not on Android or
Linux.

## Why the secret is not the fix

`expectedBridgeSecret` is one `UUID.randomUUID()` per webview
(`InAppWebView.java:231`), baked into the bridge script injected into that
webview's frames. Consequences:

- **Different sites are already separated.** Each site is its own webview, with
  its own secret and container, and cannot reach another site's JS realm. No
  cross-site secret theft is reachable.
- **Within one webview the secret separates nothing.** Every frame carries the
  same secret, so a foreign cross-origin frame already holds it. The exposure is
  not theft; it is that the native side believes the `origin` and `isMainFrame`
  the frame *sends*. Making the secret unstealable changes nothing here.

So the secret stays only as defence in depth. The fix is to stop trusting
page-supplied identity.

## Android

The fork already has `WebViewCompat.addWebMessageListener`
(`web_message/WebMessageListener.java`), whose `onPostMessage` delivers
`sourceOrigin` and `isMainFrame` from Chromium.

1. Carry the handler call over a `WebMessageListener` channel instead of the
   `@JavascriptInterface _callHandler` method. The injected `callHandler` posts
   `{handlerName, _callHandlerID, args}` through the listener's JS object; it
   no longer sends `origin` or `isMainFrame`.
2. In `onPostMessage`, dispatch with the native-supplied `sourceOrigin` and
   `isMainFrame`. Drop the page-supplied values from
   `JavaScriptHandlerFunctionData` entirely, so no handler can read them.
3. Reply through `JavaScriptReplyProxy.postMessage(...)`, not
   `evaluateJavascript("...resolve(...)")`.
4. Gate on `WebViewFeature.WEB_MESSAGE_LISTENER`. Where it is unsupported, an
   identity-bearing handler **fails closed** (answers as a foreign origin would)
   rather than trusting the page. Non-identity internal handlers may keep the
   old path.

## Linux (WPE WebKit, non-Chromium)

WebKit's GLib script-message signal delivers only
`(WebKitUserContentManager*, JSCValue* value, WebKitScriptMessageReply*)`
(`user_content_controller.cc`, `onScriptMessageWithReplyReceived`): **no
sending-frame origin, no main-frame flag.** This is still true on current
WebKitGTK/WPE (the signal, added in 2.40, keeps this shape through 2.54); an
upstream request to add frame info exists but has not landed. So the UI process
cannot learn the calling frame from this signal, and `webkit_web_view_get_uri`
returns the top document's URL for every caller.

The identity does exist, in the **web process**. The secure fix is a **WebKit
web process extension** (`WebKitWebProcessExtension`), which the fork already
loads: `webkit_web_context_set_web_process_extensions_directory`
(`webview_environment.cc:238`, settings key `webProcessExtensionsDirectory`).
The extension runs where the page's JS cannot reach it and where the real frame
is available:

1. At each frame's `window-object-cleared`, the extension binds the bridge's
   `callHandler` for that document, capturing the frame's own origin (from
   `webkit_frame`'s URI on the web-process side) and
   `webkit_frame_is_main_frame`. The page cannot forge these; they are read in
   the web process, not supplied by page script.
2. A handler call is forwarded to the UI process with that captured identity
   attached, as a user message (`webkit_web_page_send_message_to_view`), not in
   a payload the page built.
3. The UI process reads the origin and main-frame flag from the user message
   and ignores anything the page put in the call body.

This **attributes** every frame correctly, so it keeps full functionality
(cross-origin iframes still answerable per PERM-002) and is secure. It is more
work than Android's: it adds a web-process-extension library to the Linux
bundle, built against the WPE headers, loaded from the per-site container's
extension directory.

Fallback if the extension is not yet built: inject the bridge
**main-frame-only** on Linux (the bridge plugin script's `forMainFrameOnly`,
kept `false` elsewhere for the shims). Only the top document can then call a
handler, `webkit_web_view_get_uri` is that caller's own origin, and a subframe
is denied a capability by absence. This is secure (fail-closed) but a
same-origin subframe loses handler access, so it is a stopgap, not the target.

## App side

- `page_handlers.dart` keeps reading identity from
  `JavaScriptHandlerFunctionData`; once the fork fills it from the platform, no
  app change is needed for correctness.
- The `Requester` type (see the owed R2 design) can then take a private
  constructor whose only factory reads that platform-supplied identity, so a
  handler cannot build a requester from a page value. That moves R2's requester,
  CAM-013 and PASSKEY-004 from assumed to enforced.

## Verification (what this session could not run)

1. Build the plugin example and the app on an Android emulator.
2. Run the plugin's instrumented tests.
3. Add an emulator test (the app's camera/permission tier): a cross-origin
   iframe calling a capture, location, notification or passkey handler is
   attributed to the iframe's origin, never the top document's, and is denied
   the site's grant.
4. On Linux, a subframe's handler call reports the subframe's origin.

Until 1 to 4 pass, SEC-045 stays open and R2 to R4 keep their platform caveat in
[policy.md](policy.md) and their rows in [policy_debt.tsv](policy_debt.tsv).
