# BUG-012 — A page steers a Dart-side fetch onto a network it cannot reach itself

Status: open (each path found so far is closed; the class stays open until every
Dart-side fetch whose URL a page can choose is enumerated and covered)

**Spec:** [openspec/specs/user-scripts/spec.md](../../openspec/specs/user-scripts/spec.md)
— `US-006`; `US-DR-007` in
[openspec/changes/page-reachable-bridge-hardening](../../openspec/changes/page-reachable-bridge-hardening/specs/user-scripts/spec.md).
Related: [openspec/specs/background-audio/spec.md](../../openspec/specs/background-audio/spec.md)
(the media-session artwork URL).

## Symptom

Page JS hands the app a URL, the app fetches it from Dart, and the request lands
somewhere the page's own network stack would have refused: a service on
`127.0.0.1`, a device on the LAN, or the cloud metadata endpoint at
`169.254.169.254`. Where the fetch returns a body to the page (`window.__wsFetch`)
this is a read; where it does not (the media-session artwork fetch) it is still a
GET the site chose, on a host it picked.

The browser's own SOP and private-network rules do not apply, because the request
is not the browser's — it is the app's, made with the app's network position.

## Root mechanism / invariant

The app has several seams where a URL crosses from page JS into a Dart HTTP call.
Each one classifies the URL before fetching it, and *classification of a URL
string is not classification of a destination*. Every extension of the app's
reach — a redirect the client follows, a name the resolver expands, a second
call site that fetches page-supplied metadata — is a way for the destination to
end up somewhere the string never named.

What makes this recur: the guard is a **predicate over a string**, and it is
correct for exactly the transformations that were thought about when it was
written. A path that transforms the URL after the check (redirect), a layer that
transforms the name after the check (DNS), or a caller that never ran the check
(a new seam) each opts out silently, because the guard still returns "allowed"
and nothing observes what was actually contacted.

The invariant: **every Dart-side fetch whose URL page script can influence must
be judged on the address it will actually connect to, at the moment it connects,
on every hop — and a new such seam must route through the shared guard rather
than copy the range table.**

## Fix attempts

1. **2026-08-24 — the literal guard** (`a3ffe7b`, #550).
   Added `_isPrivateOrLoopbackHost` to `classifyScriptFetchUrl`, refusing
   loopback / RFC1918 / unique-local / link-local literals and the `localhost`
   name before `window.__wsFetch` or the script handler would fetch them.
   *Why:* the bridge is a page-reachable global, so any script on a
   user-script-enabled site can drive it; the obvious payload is
   `http://169.254.169.254/latest/meta-data/`.
   *Why it was partial:* the `http` package follows redirects transparently and
   the classification only ever saw the first hop, so a public host answering
   `302 Location: http://169.254.169.254/…` handed the body back regardless. The
   check also never resolved a name, so a hostname whose A record pointed into
   the range walked through untouched.

2. **2026-08-28 — the redirect half** (`04cc571`, #562, `US-006`).
   Turned off automatic redirect following and re-ran the admitting gate against
   every `Location` over a bounded 5 hops, on all three seams.
   *Why:* a whitelisted CDN must not be able to hand execution, or a private
   body, to an origin the user never approved.
   *Why it was partial:* it closed the redirect path and named the DNS-rebinding
   path as still open, pinning it as a `KNOWN GAP` test rather than fixing it.
   The same commit also copied the literal range table verbatim into
   `media_session_service.dart` for the artwork fetch — a second seam, with only
   the half that had already been shown insufficient, and no shared home to
   fix once.

3. **2026-09-09 — the resolving half** (`d0e1621`, #591, `US-DR-007`).
   Resolves the host where the fetch happens and refuses it when any address it
   names is in range, on all three bridge seams, every redirect hop, and the
   artwork fetch. Runs before the script handler's confirmation prompt, since a
   user cannot tell `http://cdn.evil.example/lib.js` from a real CDN by looking
   at it. The range table moved into `lib/services/host_resolution.dart`, which
   both former copies now use, and the lookup sits behind a conditional import
   so the check does not cost the screens their web build.
   *Why:* the literal check reads the URL string, so the same destination
   spelled as a name defeated it entirely — the cheapest possible bypass of
   everything attempts 1 and 2 built.
   *Why it is partial:* it resolves and then connects, and those are two
   separate resolutions. A record with a short TTL can flip between them.
   Skipped under any proxy by design (see gaps). And it is still a rule each
   seam opts into by calling `classifyOutboundTarget` — a fourth seam added
   tomorrow inherits nothing.

## Known open gaps

- **The TTL-flip race.** The gate resolves the name; the `http` client resolves
  it again when it connects. Closing this needs the connection pinned to the
  address that was checked, which means a `HttpClient.connectionFactory` that
  dials an `InternetAddress` while keeping TLS SNI and certificate validation
  against the original name. Not attempted; the attack needs a sub-second TTL
  and a resolver that honours it.
- **Remote-DNS proxies are exempt.** Under SOCKS5, Tor, or an HTTP proxy the
  destination name is resolved at the far end, so a local answer describes a
  network the request never traverses — and a Tor user may have no local
  resolver at all. The exemption is correct for the device's own LAN and wrong
  for the *proxy's*: a fetch through a proxy can still reach whatever is private
  to that proxy's network. Nothing on this side can see that.
- **No structural gate.** Nothing fails CI when a new Dart-side fetch takes a
  page-supplied URL without calling `classifyOutboundTarget`. Both seams found
  so far (the bridge, the artwork fetch) were found by reading code. A gate
  that greps for `outboundHttp.clientFor` in a file that also reads a
  page-supplied URL would catch the next one; per BUG-007's practice, that gate
  is the thing that makes the class stop recurring, and it is not written yet.
- **Enumeration is incomplete.** Downloads, favicon probes, and the TLS-trust
  prompt also make Dart-side requests with URLs derived from page content. They
  are subject to different rules (a download is a user action; a favicon URL
  comes from parsed markup) and have not been audited against this invariant.
