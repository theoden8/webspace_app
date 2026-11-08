# BUG-012 — A page steers a Dart-side fetch onto a network it cannot reach itself

Status: open (each path found so far is closed; the class stays open until every
Dart-side fetch whose URL a page can choose is enumerated and covered)

**Spec:** [openspec/specs/user-scripts/spec.md](../../openspec/specs/user-scripts/spec.md)
— `US-006` and `US-DR-007`.
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

4. **2026-10-07 — the literal's other spelling** (#680).
   `isPrivateOrLoopbackHost` normalises its input through `Host`, so
   `localhost.` and `127.0.0.1.` are the literals they name. Regression test:
   "a literal spelled with the root dot is the same literal" in
   `test/user_script_test.dart`. *Why:* each caller lowercased the host itself
   and none dropped the root dot, so the FQDN spelling read as a public name
   and was left to the resolving half, which a proxy skips. *Why it is
   partial:* it closes a spelling of the literal guard, nothing else in the
   gaps below.

5. **2026-11-08 — the connection pin** (SEC-049).
   A page-steered client (`pageSteeredClient`, the sole producer of
   `PageSteeredHttp`) resolves the host once and connects only to the judged
   address, http and https alike — https pins the raw socket to the judged IP and
   runs TLS with SNI and certificate verification against the hostname. The
   resolution that judges is now the resolution that connects: no byte, not even
   a TLS ClientHello, reaches an address the judge did not accept, which closes
   the TTL-flip race at the connection, where no seam can opt out of it.
   `_PageSteeredLiteralGuard` refuses a private or loopback literal on every
   route (the literal half, now uniform, including under a proxy), and a
   page-steered proxied client gets no localhost bypass. The structural gate was
   rewritten (`test/js/page_steered_outbound_reach.test.js`): the marker is now
   `pageSteeredClient`, and favicons and page icon bytes — the enumeration gap
   below — are GUARDED. Byte/connection-counting boundary test:
   `test/outbound_http_page_steered_test.dart`. The fetchers keep their own
   pre-flight range checks as defense in depth; under a proxy, where the pin is
   not built, those by-hand per-hop checks are the only redirect judge.
   *Why:* attempt 3 resolved and then connected as two separate resolutions, and
   it was a rule each seam opted into by calling `classifyOutboundTarget`; the
   pin removes both.
   *Why it is partial:* the auto-follow fetchers use `client.get`, so the
   request-level literal guard sees only hop 1; a hop-2 redirect to a private
   target is seen by no guard (see gaps).

## Known open gaps

- ~~**The TTL-flip race.**~~ Closed by attempt 5: the page-steered client resolves
  once and connects to the judged address, so there is no second resolution to
  flip.
- ~~**No structural gate.**~~ Closed: `test/js/page_steered_outbound_reach.test.js`
  fails CI when a Dart-side fetch of a page-chosen URL does not route through
  `pageSteeredClient`, unless it is listed EXEMPT with a reason.
- **Auto-follow redirect to a private target through a device-side proxy.** The
  auto-follow fetchers (favicons, page icon bytes) use `client.get`, so the
  request-level literal guard sees only the first hop. (The manual-loop fetchers
  — user scripts, media artwork, page-linked icons — judge every hop and are
  unaffected.) Under DEFAULT the pin judges every hop, and under a *remote* proxy
  a hop-2 private target is the proxy's network, not the device's. But an
  on-device *forwarding* proxy (Privoxy, a local proxy app) forwards a hop-2
  `302 -> http://127.0.0.1/` or a LAN literal to the device's own network. The
  egress relay closes the loopback half (every dial is bound to a non-loopback
  interface via `SO_BINDTODEVICE`, loopback excluded from the interface list) but
  a LAN literal on hop 2 still reaches the user's LAN through it. Closed by making
  the literal guard judge every hop on every route (`followRedirects` off +
  per-hop re-entry) for the auto-follow fetchers; not done here.
- **Remote-DNS proxies are exempt by design.** Under SOCKS5, Tor, or a remote
  HTTP proxy the destination name is resolved at the far end, so a local answer
  describes a network the request never traverses — and a Tor user may have no
  local resolver at all. The literal guard still refuses private literals on
  these routes; a name's far-end resolution is the proxy's to judge.
- **Enumeration: downloads and the TLS-trust prompt remain.** Favicons and page
  icon bytes are now GUARDED (attempt 5). A download is a user-confirmed action
  that lands in a file, not back in the page, and the TLS-trust prompt is its own
  surface; neither has been audited against this invariant.
