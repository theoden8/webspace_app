# Draft: WebKit bug report for the per-process proxy slot

Status: **draft, not filed.** Filing is the user's call. Cross-linked from
[014-per-site-setting-dropped-at-the-native-seam.md](014-per-site-setting-dropped-at-the-native-seam.md)
(attempt 58 proposed it; attempts 59-64 are the evidence).

Before filing, fill in the two placeholders below (`<OS>`, `<SAFARI>`) from the
machine that reproduces it, and search bugs.webkit.org once more in case it has
been reported since.

---

## Title

`WKWebsiteDataStore.proxyConfigurations` is honoured only for the first
WKWebView in a process; later views with their own data stores load direct

## Environment

- macOS `<OS>`, Safari/WebKit `<SAFARI>`, arm64
- Reproduced on GitHub Actions `macos-latest` runners across 10+ runs
- Also observed on iOS 17+ through the same API

## Summary

A process may create several `WKWebsiteDataStore`s, give each its own
`ProxyConfiguration`, and load a page in a `WKWebView` bound to each. Only the
**first** WebView created in the process has its store's proxy honoured. Every
later one reaches the origin directly, with no error and no indication that the
proxy was dropped.

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
tells sites apart by per-site proxy credentials.
