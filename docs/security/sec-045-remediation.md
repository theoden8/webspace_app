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

There is no clean parallel to Android's fix. WebKit's GLib script-message
signal delivers only `(WebKitUserContentManager*, JSCValue* value,
WebKitScriptMessageReply*)` (`user_content_controller.cc`,
`onScriptMessageWithReplyReceived`): **no sending-frame origin, no main-frame
flag.** `WebKitFrameInfo` exists for navigation policy decisions, not for
script messages, so the native side cannot learn the calling frame from the
platform the way Apple's `frameInfo` or Android's `addWebMessageListener` allow.
`webkit_web_view_get_uri` gives the top document's URL for every caller.

So on Linux the fix is restriction, not attribution:

- Inject the bridge **main-frame-only** on Linux (the bridge plugin script's
  `forMainFrameOnly`, kept `false` elsewhere for the shims). Then only the top
  document can call a handler, `webkit_web_view_get_uri` is that caller's own
  origin, and a foreign (or same-origin) subframe is denied a capability by
  absence rather than by a flag it supplies. The shims that need to reach
  iframes (fingerprinting, etc.) stay all-frames; only the capability bridge is
  restricted.
- Trade-off: a **same-origin** subframe of the site loses handler access it has
  today. That is the safe direction (deny), and matches what a cross-origin
  iframe gets in a browser without an `allow=` attribute.
- The only way to attribute a subframe's call on Linux is an upstream WebKit
  change exposing the frame on script messages; track that separately. Until
  then Linux keeps a residual caveat in [policy.md](policy.md): a same-origin
  subframe is denied rather than attributed.

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
