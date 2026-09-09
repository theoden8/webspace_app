## Context

See proposal.md — Why. One constraint shapes every decision below and is worth
stating once: **Dart can only reach page JS by name, in the page's own realm.**
`evaluateJavascript` has no isolated world here, so anything Dart calls is a
property the page can also read, call, and — unless something stops it —
replace. "Unreachable from the page" is not available. "Reachable but not
replaceable, and useless to a caller who is not us" is.

The second constraint is that the shims are injected `forMainFrameOnly: false`
so cross-origin subframes are covered (a QR scanner in an iframe, CAM-004).
That is a deliberate reach, and it is what puts an ad frame on the same
handlers as the page.

## Goals / Non-Goals

**Goals**

- Page script may *call* the bridge; it may not *defeat* it.
- A grant answers for the frame the popup named.
- Where a capability cannot be scoped to its requester, make having it at all
  an explicit choice.

**Non-Goals**

- Hiding the shims. The `__ws_*` markers stay page-readable; see Risks.
- Distinguishing user-script code from site code inside the page realm. The
  spec already judged this infeasible and this design agrees — it is the
  premise of US-DR-005 rather than a problem it solves.
- Any change to what a *user* is allowed to grant. Every fix narrows who
  inherits a grant, never what the user can choose.

## Decisions

### The capture-stop hook: non-replaceable, over private state

`__wsStopRealCapture` must be callable by name from the main frame's realm.
Everything else is closed over: the device-track list and the substituted-track
set live in the installing IIFE, and the property is defined
`writable: false, configurable: false`.

*Alternative considered — a per-injection nonce gating the whole hook.* The
capture shims are not in `workerScopeShims`, so their source never lands in a
page-readable blob and a baked-in secret would in fact hold. Rejected anyway:
it protects the *stop*, which is the one operation a hostile page gains nothing
from calling, and it would have to be threaded through three builders and the
fixture dumper to buy that.

*How the sibling shims still share the registry.* They need `remember` (a shim
handing over a device track) and `markSynthetic` (a shim tagging a track it
minted). Both hang off the hook function as non-enumerable properties, and both
are safe in a page's hands: one only adds tracks that will be stopped, and the
other refuses a track already registered as device-backed. That refusal is what
replaces the nonce — ordering does the work. A device track is registered while
the `getUserMedia` promise is still resolving, so the page cannot reach one
before the registry does, and a page calling `markSynthetic` to launder its own
capture finds it already real.

### Clones and subframes

Two holes that were never tampering, just gaps:

- A clone is an independently live track. `MediaStreamTrack.clone` and
  `MediaStream.clone` are wrapped to carry registration onto the copy;
  `MediaStream.clone` matches by `kind`, because the spec's clone algorithm
  need not run through the JS-visible track `clone`.
- Dart evaluates in the main frame, and a subframe granted a device track holds
  its own registry. The hook posts a fixed message down `globalThis.frames` and
  each realm's listener runs its local stop and relays onward. Forging that
  message can only *end* capture, so it needs no authentication.

### Frame scoping: gate the short-circuit, not the request

`MediaGrantEngine` already had the decide → coalesce → persist funnel. Three
edits, all in the engine layer rather than at call sites:

1. `settled` returns null for a subframe asking for `real`, so the popup runs.
   `block` and `virtual` still short-circuit — they involve no device, and
   prompting for them would train the user to dismiss popups.
2. `persist` runs only for the top document, so one frame cannot flip the
   site's stored mode.
3. `_inFlight` is keyed by prompt origin instead of being a single slot, so a
   subframe never rides the answer given for the top document.

*Where `isMainFrame` comes from.* The plugin's bridge preamble computes it (and
`origin`) behind the bridge secret, so page script can neither forge it nor call
the handler around it — the same property SHARE-005 already relies on. The
native `onPermissionRequest` path has no frame identity, so it compares the
request origin against the live top-level origin instead.

*The grace window.* Allowing a frame makes the shim call the real
`getUserMedia`, and the platform's permission request arrives milliseconds
later for the same origin. Without a 30-second per-origin memo the user answers
the same question twice. Keyed by prompt origin, so it can only ever return the
answer given for that exact frame. Considered and rejected: treating the native
path as always-top-frame (silently re-opens the hole for a frame the shim
missed) and denying subframes natively (voids the approval the user just gave).

### The privileged bridge: scope the grant, not the caller

The bridge is prototype wrappers and page globals, so whoever shares the
document shares it. What *is* scopable is whether a site has it. Hence
`bypassSitePolicy` on `UserScriptConfig`, gating both the shim and handler
registration.

*Migration.* Absent key → `true` when the script is library-backed
(`url`/`urlSource`), else `false`. A blanket `true` would fix nothing for
existing users; a blanket `false` would silently break working DarkReader
setups on upgrade. Library-backed is the case US-DR-001 was written for, so it
is the one that keeps working.

*`window.fetch`.* Deleted rather than scoped. Even for a site that asked for the
bridge, wrapping `fetch` hands every CORS refusal on the page back as a body,
and the retry cannot carry the original method, headers or body — a refused
`POST` came back as the response to a `GET` the server saw twice. Libraries use
the documented `setFetchMethod(window.__wsFetch)` instead.

### Relay peer ownership

`/proc/net/tcp{,6}` lists only the calling UID's sockets on API 29+, so a
connection this process opened appears as a row whose local port is the peer's
and whose remote port is the relay's. The parse is a pure function
(`ProxyRelay.peerVerdict`) taking the table contents, so the JVM tests can cover
the foreign case that no test could otherwise arrange.

*Alternatives.* `SO_PEERCRED` is Unix-socket only. A shared secret cannot work:
`ProxyController` carries no credentials, which is the whole reason the relay
exists.

## Risks / Trade-offs

- **A subframe in `real` mode now prompts per request** (after burst
  coalescing and the grace window) → Accepted: browsers deny a non-delegated
  frame outright, so prompting is still more permissive than the platform. A
  future `allow="camera"` check could restore silence for a delegated frame.
- **Existing library-backed scripts keep the bridge** → the migration is
  behaviour-preserving by design, so those users are no better off until they
  turn the flag off. The flag is visible in the editor with what it costs.
- **The main-frame media rule can lock out a legitimate second player** on a
  site whose top document is also playing → Accepted: the top document is what
  the user is looking at.
- **Relay check fails open on an unreadable `/proc`** → Accepted and logged
  once per relay. Failing closed would strand proxying entirely for a threat
  that needs a malicious app already installed.
- **The `__ws_*` markers still identify the app and its enabled features**, and
  `__wsFetchShimInstalled` still advertises that the bridge is present → Not
  addressed here. The fix is per-instance randomized names, as the user-script
  handler names already use; it touches every shim, the worker payload, the
  dumper and every test naming a marker, and it only raises the cost of
  detection rather than removing it (canvas noise stable per site, or a
  `hardwareConcurrency` disagreeing with the UA, still give the shims away).

## Migration Plan

No data migration and no ordering constraint against the two sibling changes.
`bypassSitePolicy` is derived on read for any script stored without it, so a
downgrade simply re-derives it; nothing is written that an older build cannot
parse.
