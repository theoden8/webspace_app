# Provenance

`meekutls.go` stands in for lyrebird's `transports/meeklite/transport.go`,
which is GPL-3.0-or-later and the one GPL file of meek_lite. This records
what was read to write it, what was not, and what changed from its source.

## Not read

- lyrebird's `transports/meeklite/transport.go`. The tree read here was
  checked out at lyrebird-0.8.1 (`0b10edbb61e0ca6fb70c7d57aeaabf315f1fade1`)
  without it, `internal/x25519ell2` and `LICENSE-GPL3.txt`:
  `git checkout FETCH_HEAD -- . ':(exclude)transports/meeklite/transport.go' ':(exclude)internal/x25519ell2' ':(exclude)LICENSE-GPL3.txt'`,
  so the file was never on disk.
- Any other meek client under the GPL, and the obfs4proxy commit that
  `meek-client/utls.go`'s comment cites as the source of its idea.

## What transport.go has to provide

Read from the compiler, not from the file. With lyrebird's meeklite less
transport.go in the tree `build.sh prepare` makes, `go build` of
`.../lyrebird/transports/meeklite` in IPtProxy's module reports one error:

```
../lyrebird/transports/meeklite/meek.go:396:8: undefined: newRoundTripper
```

Its one call site, in `newMeekConn`:

```go
var rt http.RoundTripper
switch ca.utls {
case nil:
	rt = &http.Transport{Dial: dialFn}
default:
	rt = newRoundTripper(dialFn, ca.utls)
}
```

`dialFn` is a `base.DialFunc` (`func(string, string) (net.Conn, error)`,
`transports/base/base.go`) and `ca.utls` a `*utls.ClientHelloID` that is not
nil, so the function is `newRoundTripper(dial func(network, addr string)
(net.Conn, error), clientHelloID *utls.ClientHelloID)` returning anything an
`http.RoundTripper` takes. Nothing else in the tree names an identifier that
is not declared once transport.go is gone. `certs.go`'s `GetRootCAs`, a
workaround for old Android releases by its own comment, is then called by
nothing; `meekutls.go` leaves it so and verifies against the system's roots.

## Sources

| Source | Licence | Used for |
|---|---|---|
| [meek](https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/meek) `meek-client/utls.go` at `d8ee8e88c5d73ced19c78f884a868114a8421170` (David Fifield) | CC0-1.0 (`COPYING`) | the design and most of the code: a uTLS dial, a first connection that reads the protocol the server chose, an `http2.Transport` or an `http.Transport` for it, whose first dial takes that connection, and the check that later connections choose the same |
| meek `meek-client/meek-client.go` | CC0-1.0 | its `httpRoundTripper`: `http.DefaultTransport` cloned, with `Proxy` nil |
| meek `meek-client/utls_test.go` | CC0-1.0 | read for how it drives a round tripper; the tests here are new |
| meek `meek-server/` | CC0-1.0 | the interop test's server (`go/iptproxy/interop/`), built by `go/iptproxy/build.sh upstream` |
| [lyrebird](https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird) `transports/meeklite/meek.go`, `base.go` | BSD-2-Clause (their headers) | the call site above; that a failed request moves to the next front (`roundTrip`) |
| lyrebird `transports/meeklite/certs.go`, `frontlist.go`, `meek_test.go`, `README.md` | BSD-2-Clause (lyrebird's `LICENSE`; no header) | the bridge line's `url=`, `front=` and `targets=` |
| lyrebird `common/utlsutil/clienthelloID.go`, `transports/base/base.go` | BSD-2-Clause | how `utls=` becomes the hello (Chrome's when absent, nil for `none`); `DialFunc` |
| [uTLS](https://github.com/refraction-networking/utls) v1.8.2 | BSD-3-Clause | `UClient`, `UConn.HandshakeContext`, `Config.Clone`, `CertificateVerificationError`; `hostnameInSNI`, which keeps an IP address out of the SNI; `generateRandomizedSpec` and `DefaultWeights`, for the limit below |
| `golang.org/x/net` v0.56.0 `http2` | BSD-3-Clause | `Transport.DialTLSContext`, `IdleConnTimeout` |
| Go 1.26.10 `net/http` | BSD-3-Clause | why a connection from `DialTLSContext` is spoken to in HTTP/1.1 (`dialConn` reads the state of a `*tls.Conn` only); `httptest` for the tests |

## Changed from meek-client/utls.go

uTLS moved from v1.1.5, which meek pins, to v1.8.2, which IPtProxy 5.5.1's
`go.mod` selects; the calls the file makes kept their shape.

- `newRoundTripper(dial, clientHelloID)` in place of
  `NewUTLSRoundTripper(name, cfg, proxyURL)`: lyrebird parses the hello's
  name, and IPtProxy puts any proxy in `dial`, so the name table and the
  proxy dialers (`makeProxyDialer`, `ProxyHTTP`, `ProxyHTTPS`) are gone.
- One transport per address dialled, where meek-client keeps one for all:
  meek.go moves to the next front when one fails, and each front's server
  chooses its own protocol.
- The server name is set in the configuration from the address, as
  crypto/tls does, where meek-client calls `SetSNI`: an IP address is then
  checked against the certificate and not sent as SNI.
- The handshake runs under `HandshakeContext`, within
  `http.DefaultTransport`'s `TLSHandshakeTimeout`; meek-client's had no limit.
- `DialTLSContext` in place of the deprecated `DialTLS`, and the
  `http2.Transport` takes `http.DefaultTransport`'s `IdleConnTimeout`, where
  meek-client's keeps an idle connection for ever.
- A later connection whose protocol differs is closed, not left open, and a
  request that is not sent has its body closed, as `http.RoundTripper` asks.

## Known limit

uTLS cannot answer a HelloRetryRequest for X25519MLKEM768. A Go 1.26 server
sends one to a hello that lists the group without a key share for it, which
some randomized hellos do (`generateRandomizedSpec`: TLS 1.3, the group
listed and no share for it, 0.4 x 0.71 x 0.5 by `DefaultWeights`, about one
handshake in seven). meek.go retries a failed request up to ten times, each
with a new hello. Chrome's hello sends that share.
