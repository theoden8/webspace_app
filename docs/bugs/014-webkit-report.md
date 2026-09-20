# Draft: WebKit bug report for the per-process proxy slot

Status: **draft, NOT FILED. BLOCKED AGAIN as of attempt 78 (2026-09-20).**
Its central claim -- a single per-process proxy slot -- is refuted by the
evidence below, and filing it as written would get it closed by the first
person who reproduces three proxied stores at once. Do not file until the
claim is restated around something that survives. What is written below is
kept as the record of what was believed, not as a document to send.

**What refutes it** (run 35516286156, `proxy_relay_binding_test`, containers=true):

```
verdict: first-frame-socks-control=proxied,
         first-frame=[s0->own(socks0) s1->own(socks1)],
         later-frame=[s2->DIRECT s3->DIRECT]
socks0 connects=[192.168.64.4:50374]
socks1 connects=[192.168.64.4:50376]
```

Two stores reached two *different* SOCKS upstreams simultaneously, with a third
proxied control in the same process. Three proxied stores at once, so there is
no slot to contend for. `proxy_rate_test` refutes the completion-ordering half
in the same run: `rounds=[DIRECT DIRECT DIRECT DIRECT DIRECT DIRECT proxied
proxied]` -- the same repeated load went direct six times and then bound twice.

**What survives and is not yet sharp enough to file.** A store built after the
first frame has gone DIRECT in every arrangement that measured one, and
first-frame binding varies per app process (in that same run
`proxy_simultaneous` read its whole first frame DIRECT). The one reading that
sharpened rather than fell is the `count=1` readback: a store reports exactly
one `proxyConfigurations` entry at navstart and loads direct anyway, so the
drop is downstream of the store's own property. That is the observation a
future report should be built on.

---

Earlier status, superseded: draft, no longer blocked. Filing is the user's call.
Attempt 71 blocked this because the probe released each store before the next
arm ran, so the readings described sequential use rather than coexistence.
Attempt 72 re-measured it with every store alive -- `liveStores` reads 1 to 6
across the arms -- and the result stands: arms 2 through 6 went direct with
arms 1 through 5 alive throughout. The mechanism was never deallocation.
Cross-linked from
[014-per-site-setting-dropped-at-the-native-seam.md](014-per-site-setting-dropped-at-the-native-seam.md)
(attempt 58 proposed it; attempts 59-64 are the evidence, 72 is the
coexistence measurement).

Before filing, fill in the two placeholders below (`<OS>`, `<SAFARI>`) from the
machine that reproduces it, and search bugs.webkit.org once more in case it has
been reported since.

---

## Title

A second `WKWebsiteDataStore`'s `proxyConfigurations` is not used: the WebView
loads direct while the store still reports its configuration

## Environment

- macOS `<OS>`, WebKit `<WEBKIT>`, arm64
- `WKWebView` embedding API. Nothing here was measured in Safari, which does
  not expose per-store proxy configurations to a host application.
- Reproduced on GitHub Actions `macos-latest` runners across 10+ runs
- Also observed on iOS 17+ through the same API

## Summary

A process may create several `WKWebsiteDataStore`s, give each its own
`ProxyConfiguration`, and load a page in a `WKWebView` bound to each. The first
such load is proxied. A second store's load reaches the origin **directly**,
with no error and no indication that the proxy was dropped.

Pointing the second store at **the same proxy endpoint** as the first does not
help: it loads direct too, and the proxy records a single CONNECT, from the
first store only. So the limit is one proxied *store* per process, not one
proxy per process.

What decides it may be **completion** rather than creation, though the two are
not yet separable. Across more than ten runs, a second proxied store never used
its proxy once the first store's load had completed. In two runs where the first
load hung instead of completing, the second store *was* proxied and a third was
not -- so a load still in flight
has not yet taken the slot, and the next load to complete takes it. Either
way a second site is not proxied in ordinary use, where the first load
finishes.

In every failing case the store still reports its configuration:
`store.proxyConfigurations.count == 1` immediately before the load, and the
navigation completes normally (`didFinish`). The proxy is simply not used.

This is not documented. `WKWebsiteDataStore.h` says only that changing the
configurations "might interupt current networking operations in any WKWebView
that use this WKWebsiteDataStore, so it is encouraged to finish setting the
proxy configurations before starting any page loads" -- a per-store caution
about interruption, not a per-process limit of one.

## Steps to reproduce

Two non-persistent data stores, two SOCKS5 proxies on loopback, two WebViews,
one process. Both proxies are reachable and both record every CONNECT they are
asked for. The destination must be non-loopback: WebKit never proxies a
loopback destination, which makes a naive repro look like a pass.

```swift
func probe(port: UInt16, url: URL, done: @escaping () -> Void) -> WKWebView {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(IPv4Address("127.0.0.1")!),
                                       port: NWEndpoint.Port(rawValue: port)!)
    let store = WKWebsiteDataStore.nonPersistent()
    store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
    assert(store.proxyConfigurations.count == 1)

    let config = WKWebViewConfiguration()
    config.websiteDataStore = store
    let view = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 200),
                         configuration: config)
    view.navigationDelegate = delegate   // completes on didFinish/didFail
    view.load(URLRequest(url: url))
    return view                          // retain it: a released view reports nothing
}

// first proxy A, then, after it finishes, proxy B
let a = probe(port: proxyA.port, url: originA) { /* ... */ }
let b = probe(port: proxyB.port, url: originB) { /* ... */ }
```

## Expected

Proxy A records a CONNECT for `originA`, and proxy B records one for
`originB`.

## Actual

Proxy A records its CONNECT. **Proxy B records nothing**, and `originB`'s
server sees the request arrive directly from the host's own address. Both
navigations report `didFinish`.

The same happens when both stores point at the *same* proxy endpoint, so it is
not a limit of one distinct upstream per process.

It is also independent of the proxy type, which matters because the two types
take different paths inside `NetworkSessionCocoa::setProxyConfigData`: a
SOCKS5 configuration is applied by patching the live `nw_context`
(`nw_context_clear_proxies` then `nw_context_add_proxy`), while an HTTP
CONNECT configuration passes
`nw_proxy_config_stack_requires_http_protocols` and instead goes through
`recreateSessionWithUpdatedProxyConfigurations`. Two CONNECT proxies on
separate ports behave exactly like two SOCKS5 proxies: the first store's load
is proxied and the second store's is not.

## What this is not

Each of these was tested with a positive control in the same process, meaning
an arm known to proxy ran alongside it; a run where the control failed was
discarded rather than read.

- **Not the store shape.** `nonPersistent()` and
  `WKWebsiteDataStore(forIdentifier:)` behave identically, first or later.
- **Not the view hierarchy.** Adding the WebView to a window's content view
  changes nothing.
- **Not the load mechanism.** `initialUrlRequest` at creation and `loadUrl`
  after creation behave identically.
- **Not a timing race.** A later view still goes direct after the first has
  fully finished, and eight consecutive loads in one view after the first all
  go direct.
- **Not the destination scheme.** http and https behave the same.
- **Not stored data-store state on disk.** A process that starts with no
  stored stores behaves the same as one that starts with six, and deleting
  them changes nothing.

## A contrast worth stating carefully

The same application, on WPE WebKit, routes four data stores through three
distinct SOCKS5 upstreams in one process, and a further pair built in a later
frame:

```
first-frame=[p0->own(socks0) p1->own(socks0) p2->own(socks1) p3->own(socks2)]
later-frame=[l0->own(socks0) l1->own(socks1)]
```

**This is not evidence that the Apple port regressed against its sibling, and
it is not offered as such.** The two ports do not share this code:
`NetworkSessionSoup::setProxySettings` goes to libsoup per `SoupSession`,
while `NetworkSessionCocoa::setProxyConfigData` goes to Network.framework via
`nw_context_add_proxy`. They are independent implementations of a
similar-sounding feature, so one working says nothing about what the other is
specified to do.

What the contrast does establish is narrower and still useful: an application
wanting one proxy per storage partition is expressing something a WebKit port
can support, and the shape of the request is not inherently unreasonable.

## Is this a defect or an undocumented limit?

Stated honestly, because the answer changes what should be done about it.
`WKWebsiteDataStore.h` says only that changing the configurations "might
interupt current networking operations in any WKWebView that use this
WKWebsiteDataStore, so it is encouraged to finish setting the proxy
configurations before starting any page loads". That is a per-store caution
about interruption, but it is also consistent with an API designed around one
set of proxy configurations per network session lifetime, in which case the
behaviour below is a documentation gap rather than a bug.

Either way the observable result is the same and is worth reporting: the
second store reports its configuration, the load completes, and the proxy is
silently not used.

## Why it matters

An application that isolates sites by data store -- one store per site, each
with its own proxy -- cannot proxy more than one of them per launch. The
second site silently uses the device's own address. For a privacy feature such
as routing one site through Tor, a silent fallback to the direct path is worse
than a failure, because nothing tells the user or the application that the
isolation was lost.

## Related

- Bug 264309, `Proxy-Authorization` not sent for a CONNECT proxy configured
  through this API (RESOLVED/MOVED, rdar://118028838, FB13343450)
- FB13350370 / r.113346270, `ProxyConfiguration.applyCredential` in WebKit,
  confirmed a bug by DTS

Those two close the obvious workaround: a single shared proxy endpoint that
tells sites apart by per-site proxy credentials. Measured on current macOS
rather than taken from those reports: a CONNECT proxy configured this way is
reached and answers `407`, no `Proxy-Authorization` is ever sent in response,
and the navigation then hangs rather than failing.
