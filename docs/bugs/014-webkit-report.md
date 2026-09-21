# BUG-014 upstream brief: a later navigation ignores the data store's proxy configuration

Status: **not filed.** Two audiences, in this order:

1. **An agent with a WebKit checkout.** Everything below "Reading the source"
   is a work order: the exact functions to instrument, the questions a build
   with logging must answer, and the one contradiction that source reading
   alone cannot resolve. That is the cheapest remaining path, and it is
   cheaper than another 70-minute CI tier run.
2. **bugs.webkit.org / Feedback Assistant**, once question Q1 below is
   answered. Filing before that risks a report whose central claim is
   explained by the reporter's own environment.

Cross-linked from
[014-per-site-setting-dropped-at-the-native-seam.md](014-per-site-setting-dropped-at-the-native-seam.md);
the evidence here is attempts 90, 91, 92, 94, 95 and 96 of that file.

**An earlier draft of this file claimed one proxied store per process. That
claim is refuted** -- four stores reached four separate upstreams in one
process (attempt 91), two of them separated only by a proxy credential. It has
been removed rather than softened. What follows is what survived it.

---

## The claim

A `WKWebsiteDataStore` with a `ProxyConfiguration` proxies the navigation
issued in the turn that mounts its `WKWebView`. **Every navigation after that
reaches the origin directly**, with no error, no `didFail`, and no change to
anything the embedding application can read. A store built *and* navigated in
a later turn is direct on its own first navigation, so this is not "the
store's first load" -- it is the frame the navigation is issued in.

Multiple simultaneous proxied stores work. One store proxying more than one
navigation does not.

## Environment

- GitHub Actions `macos-latest`, arm64. `<OS>` and `<WEBKIT>` must be filled
  from a run's log before filing; the readings below span 2026-09-20/21.
- `WKWebView` embedding API. Nothing here was measured in Safari, which does
  not expose per-store proxy configurations to a host application.
- Also observed on iOS 17+ through the same API.
- Both store shapes: `nonPersistent()` and `WKWebsiteDataStore(forIdentifier:)`.

## The four controlled readings

"Controlled" means a positive proxy control ran **in the same process**: an
arm known to proxy, proving the process could. A run whose control read DIRECT
is discarded, for the reason in "Confounds" below.

**Attempt 90** (run 35601872325). One `WKWebView`, one store, two loads:

```
pair=2 of 2 proxied      raw-first=proxied       raw-second=DIRECT
persist-inpage=DIRECT    persist-loadurl=DIRECT
arrived=a+b
```

`pair=2 of 2` is the control: two stores proxied at once in this process.
`raw-first` then `raw-second` is the claim. Both routes to a second navigation
agree -- the page's own `location.href` and `loadUrl` called from the host --
and `arrived=a+b` means the origin received both, so these are bypasses and
not failures.

**Attempt 91** (run 35629531072). Delivery crossed against destination:

```
run=last verdict: containers=true control=proxied
  f1-connect-https-a=own  f1-connect-https-b=own
  f1-socks-https=own      f1-socks-http=own
  late-connect-https=DIRECT  late-socks-https=DIRECT
```

`late-connect-https` and `late-socks-https` were built **and** navigated in a
later turn, so DIRECT is on their own first navigation. `own` means each of
the four frame-1 cells reached its own upstream fixture and no other:
four simultaneous proxied stores, and `-a`/`-b` share one relay endpoint and
differ only by `Proxy-Authorization: Basic`, so the credential is delivered.

**Attempt 94** (run 35650198541), SOCKS5, and **attempt 96** (run 35659213308),
CONNECT. One store, one WebView, two navigations to two *different* origins,
with the configuration assigned a second time in between:

```
[proxy-reassign] verdict: kind=connect reassign=true baseline=proxied second=DIRECT
[proxy-reassign] ok=true reassigned=true configured=1 detail1=didFinish secondDetail=didFinish
[proxy-reassign] connect targets=[192.168.64.2:49970]
```

Two different origins, so the fixture attributes by the port it was asked for
and a reused connection cannot account for the reading. The fixture records a
CONNECT target *before* dialling; it recorded origin A and only origin A.

## What it is not

Each was tested with a positive control in the same process.

- **Not the delivery mechanism.** CONNECT and SOCKS5 fail identically on a
  later navigation. This matters because they take different branches of
  `NetworkSessionCocoa::setProxyConfigData` (below).
- **Not a re-assignment that never happened.** Assigning
  `proxyConfigurations` again, after the session certainly exists, does not
  restore it -- on *either* branch (attempt 94 patches a live `nw_context`,
  attempt 96 rebuilds every `NSURLSession`).
- **Not the store shape.** `nonPersistent()` and `forIdentifier:` behave
  identically, first navigation or later.
- **Not the store's age.** Pre-creating a hidden WebView per site at startup
  and navigating it lazily does not keep the proxy.
- **Not the view hierarchy.** Adding the WebView to a window's content view
  changes nothing.
- **Not the load mechanism.** `initialUrlRequest` at creation and `loadUrl`
  after creation behave identically; so does the page navigating itself.
- **Not the destination scheme.** http and https behave the same.
- **Not `allowFailover`.** Pinning it false gives a byte-identical verdict.
- **Not on-disk store state.** A process starting with no stored stores
  behaves the same as one starting with six.
- **Not a loopback destination.** WebKit never proxies a loopback
  destination, which makes a naive repro look like a pass; every destination
  here is non-loopback.

## Reading the source

`WebsiteDataStore.cpp`, `NetworkProcessCocoa.mm`, `NetworkSessionCocoa.{h,mm}`
read end to end. Three places drop a proxy configuration **silently**, and one
of them contradicts the measurement.

**1. `WebsiteDataStore::setProxyConfigData` clears the member a session is
built from, then calls the network process, then restores it.** From commit
`eb352590` (274287@main, "Proxy configuration should apply after a network
process crash", bug 268952):

```cpp
void WebsiteDataStore::setProxyConfigData(Vector<std::pair<Vector<uint8_t>, WTF::UUID>>&& data)
{
    m_proxyConfigData = std::nullopt;
    protectedNetworkProcess()->send(Messages::NetworkProcess::SetProxyConfigData(m_sessionID, data), 0);
    m_proxyConfigData = WTFMove(data);
}
```

The same change gave `parameters()` a
`networkSessionParameters.proxyConfigData = m_proxyConfigData;`. A session
built from `parameters()` between the first and last line gets `std::nullopt`.
`protectedNetworkProcess()` sits inside that window and launches the process
when it is not already up.

**2. The message is dropped when the session does not exist yet.**

```cpp
void NetworkProcess::setProxyConfigData(PAL::SessionID sessionID, Vector<...>&& proxyConfigurations)
{
    CheckedPtr session = networkSession(sessionID);
    if (!session)
        return;
    session->setProxyConfigData(WTF::move(proxyConfigurations));
}
```

No queue, no error, no retry. Combined with (1): a store whose session is
created during that call gets a session with no proxy **and** drops the
message that would have supplied one.

**3. An empty list positively unproxies, and the whole apply is skipped when a
soft-linked symbol is missing.** `NetworkSessionCocoa::setProxyConfigData`
resolves `nw_context_clear_proxies`, `nw_context_add_proxy`,
`nw_proxy_config_create_with_agent_data` and
`nw_proxy_config_stack_requires_http_protocols`, and returns silently if any
is null. Downstream:

```cpp
if (!m_nwProxyConfigs.isEmpty()) { ... configuration.proxyConfigurations = nwProxyConfigurations.get(); }
else configuration.proxyConfigurations = @[ ];
```

`SessionWrapper::initialize` calls this, so a wrapper created while
`m_nwProxyConfigs` is empty is not left alone -- it is explicitly set to no
proxy.

**Two explanations this read kills.** "A wrapper created late misses out" is
wrong: `initialize` calls `applyProxyConfigurationToSessionConfiguration`.
"Some wrapper class is never patched" is wrong too: `forEachSessionWrapper`
covers `m_defaultSessionSet`, `m_perPageSessionSets` and
`m_perParametersSessionSets`, each over `sessionWithCredentialStorage`,
`ephemeralStatelessSession`, `appBoundSession` and every entry of
`isolatedSessions`, and `IsolatedSession` holds exactly one wrapper.

## The contradiction

```cpp
if (requiresHTTPProtocols(nwProxyConfig.get()))
    recreateSessions = true;
...
if (recreateSessions) {
    forEachSessionWrapper([this](SessionWrapper& sessionWrapper) {
        if (sessionWrapper.session)
            sessionWrapper.recreateSessionWithUpdatedProxyConfigurations(*this);
    });
    return;
}
// otherwise: patch the live nw_context of each existing wrapper
```

A CONNECT configuration satisfies `requiresHTTPProtocols` and takes the first
branch, which destroys and rebuilds every `NSURLSession` through
`SessionWrapper::initialize`, which sets `configuration.proxyConfigurations`
from `m_nwProxyConfigs`. **If that ran with a populated `m_nwProxyConfigs`,
the rebuilt sessions carry the proxy and attempt 96's second navigation should
have been proxied. It was not.**

So either `m_nwProxyConfigs` was empty at rebuild time -- which points back at
the clear in (1) -- or the navigation is served by something
`forEachSessionWrapper` does not walk. The source says the wrapper list is
exhaustive for a `SessionSet`, which leaves the first, and nothing readable
from source says why the member would be empty there.

That is the wall. It needs a build that can say.

## Work order for an instrumented WebKit build

Build WebKit locally, run the repro under it, and log at these points. Each
question is answerable by one log line.

**Q1 (decides whether this is filable at all).** Is `m_nwProxyConfigs`
non-empty in `NetworkSessionCocoa` at the moment the *second* navigation picks
a session? Log its size on entry and exit of `setProxyConfigData`, and again
wherever a task is matched to a wrapper. If it is empty, the bug is the clear
in `WebsiteDataStore::setProxyConfigData` and the report writes itself; if it
is populated, the bug is in wrapper selection and the report is a different
one.

**Q2.** Does `NetworkProcess::setProxyConfigData`'s `if (!session) return`
fire for this store, and when -- at store creation, at first navigation, or
not at all? Log `sessionID` and the null result.

**Q3.** Which branch does `NetworkSessionCocoa::setProxyConfigData` take for a
SOCKS5 config and for a CONNECT config on this OS, and do all four soft-linked
symbols resolve? A null symbol makes every reading in this file an artefact of
one OS build.

**Q4.** Does `applyProxyConfigurationToSessionConfiguration` ever take its
`@[ ]` else-branch during the repro, and for which wrapper and which
`SessionSet`?

**Q5.** Which wrapper serves navigation 1 and which serves navigation 2? If
they differ, that alone explains everything above. Log the `SessionSet` and
the wrapper kind at task creation; confirm the exact entry point in the
checkout rather than trusting a name from this document.

**Q6 (cheap, unrelated to the build).** Does
`com.apple.WebKit.Networking` crash during the repro? WebKit 264307 (CONNECT
with TLS crashes the network process, after which the configuration is
ignored) is a live candidate for the confound below, and this project's crash
capture globs only `Webspace*` and `Runner*` in `DiagnosticReports`.

## Confounds a reader must know

**The readback is not evidence.** `WKWebsiteDataStore`'s getter is a UI-process
cache:

```objc
- (NSArray<nw_proxy_config_t> *)proxyConfigurations { return _proxyConfigurations.get(); }
```

It never asks the network process. Every `configured=1` and `count=1` in this
investigation -- ninety-odd attempts of it -- proves only that the UI process
remembers what was assigned. The network process's state has never been
observed from outside.

**One app process at a time can proxy at all.** On these runners, an app
process either can proxy or cannot, for its whole life, and a process that
cannot goes direct on everything including a plain `URLSession` holding a
`ProxyConfiguration` nothing else has touched. It is held and released late:
one measurement saw it come back twenty-six minutes and a dozen unrelated
processes later. The cause is unknown and may be environmental.

This is why every reading above carries an in-process control, and why arms
without one are discarded rather than read as negative. **An upstream reader
reproducing this must check their control first**, or they will read a
process-level denial as the bug and dismiss it as noise.

## Unreconciled

An August 2026 audit of this exact API (Mysk, covering Onion Browser, Psylo
and iCloud Private Relay) enumerates three bypasses -- DNS prefetching,
WebAuthn Related Origin Requests, WebTransport -- and reports **no** bypass of
ordinary main-frame navigation or its subresources. Four controlled readings
here say otherwise. Either their setting differs from this application's in a
way nobody has named, or this application does something to its stores that
they do not. Q1 is the question most likely to tell them apart, and this
should be resolved before filing.

Those three bypasses are unmitigated in this application and untested by any
arm here. Psylo blocks `dns-prefetch` hints and disables WebTransport and
WebAuthn by default.

## Repro

Two data stores, two SOCKS5 proxies on loopback, two WebViews, one process;
then one store, one WebView, two navigations to two different origins. Both
fixtures record every CONNECT target *before* dialling, so attribution is per
request rather than per connection. Destinations must be non-loopback.

```swift
func probe(port: UInt16, url: URL, done: @escaping () -> Void) -> WKWebView {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(IPv4Address("127.0.0.1")!),
                                       port: NWEndpoint.Port(rawValue: port)!)
    let store = WKWebsiteDataStore.nonPersistent()
    store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]

    let config = WKWebViewConfiguration()
    config.websiteDataStore = store
    let view = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 200),
                         configuration: config)
    view.navigationDelegate = delegate   // completes on didFinish/didFail
    view.load(URLRequest(url: url))
    return view                          // retain it: a released view reports nothing
}

// control: both proxied, to separate upstreams, at once
let a = probe(port: proxyA.port, url: originA) { }
let b = probe(port: proxyB.port, url: originB) { }

// the claim: a's next navigation, to a third origin, is direct
```

Working versions of both shapes, with the fixtures:
[`macos/Runner/ProxyProbePlugin.swift`](../../macos/Runner/ProxyProbePlugin.swift),
[`integration_test/proxy_reassign_test.dart`](../../integration_test/proxy_reassign_test.dart),
[`integration_test/proxy_matrix_test.dart`](../../integration_test/proxy_matrix_test.dart).

## Why it matters

An application that isolates sites by data store -- one store per site, each
with its own proxy -- proxies each site's landing page and then silently uses
the device's own address for everything the user clicks. For routing a site
through Tor, a silent fallback to the direct path is worse than a failure:
nothing tells the user or the application that the isolation was lost.

## Related

- Bug 264307, CONNECT with TLS crashes the network process, after which the
  configuration is ignored
- Bug 264309, `Proxy-Authorization` not sent for a CONNECT proxy configured
  through this API (RESOLVED/MOVED, rdar://118028838, FB13343450)
- FB13350370 / r.113346270, `ProxyConfiguration.applyCredential` in WebKit,
  confirmed a bug by DTS

The middle one is contradicted by attempt 91's `f1-connect-https-a`/`-b`,
which share an endpoint and are told apart by `Proxy-Authorization: Basic`
alone, both reaching `own`. On this OS the credential is sent.

## A contrast, offered narrowly

The same application on WPE WebKit routes four data stores through three
distinct SOCKS5 upstreams in one process, and a further pair built in a later
frame:

```
first-frame=[p0->own(socks0) p1->own(socks0) p2->own(socks1) p3->own(socks2)]
later-frame=[l0->own(socks0) l1->own(socks1)]
```

**This is not evidence that the Apple port regressed against its sibling.**
The two do not share this code: `NetworkSessionSoup::setProxySettings` goes to
libsoup per `SoupSession`, `NetworkSessionCocoa::setProxyConfigData` to
Network.framework via `nw_context_add_proxy`. One working says nothing about
what the other is specified to do. What it does establish is that one proxy
per storage partition is a shape a WebKit port can support.

## Is this a defect or an undocumented limit?

`WKWebsiteDataStore.h` says only that changing the configurations "might
interupt current networking operations in any WKWebView that use this
WKWebsiteDataStore, so it is encouraged to finish setting the proxy
configurations before starting any page loads". That is a per-store caution
about interruption. It is also consistent with an API designed around one set
of configurations per network session lifetime, in which case this is a
documentation gap rather than a bug.

Either way the observable result is the same and is worth reporting: the store
reports its configuration, the navigation completes, and the proxy is silently
not used.
