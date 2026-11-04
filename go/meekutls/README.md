# meekutls

meek_lite's uTLS round tripper, the one function lyrebird's meek_lite takes
from its GPL `transports/meeklite/transport.go`:

```go
func newRoundTripper(dial func(network, addr string) (net.Conn, error), clientHelloID *utls.ClientHelloID) *meekutlsRoundTripper
```

meek.go calls it when a bridge line names a uTLS hello (`utls=`, Chrome's
when it names none), and sends every request of the meek_lite connection
through it. `go/iptproxy/build.sh prepare` deletes transport.go and copies
`meekutls.go` into `transports/meeklite/` beside it, so the file is
`package meeklite` here too; `build.sh check` fails on a tree or a framework
built otherwise.

What it does:

- Every connection is made by `dial`, which carries the bridge's proxy if it
  has one, and handshaken with uTLS and the given hello.
- The first request to an address dials it and reads the protocol the server
  chose: h2 gets an `http2.Transport`, anything else an `http.Transport`, and
  that transport's first dial is handed the connection. `http.Transport`
  alone would speak HTTP/1.1 to an h2 server over a connection it did not
  dial with crypto/tls.
- A later connection to that address that chooses another protocol is
  refused.
- `http:` URLs take no TLS and go through `dial` as well.

## Test

```sh
go test ./...
```

| Test | Checks |
|---|---|
| `TestRoundTripSpeaksTheProtocolTheServerChose` | HelloRandomizedALPN and Chrome's hello, against an HTTP/1.1 and an h2 server under a test root: each request crosses in the server's protocol, to the front's name and with the host behind it, over the first connection; Chrome's hello carries GREASE |
| `TestLaterConnectionsSpeakTheSameProtocol` | concurrent requests: HTTP/1.1 opens a connection each, all uTLS; h2 shares one |
| `TestRefusesAProtocolSwitch` | a server that chooses h2 on a later connection is refused there |
| `TestRefusesACertificateItCannotVerify` | meek_lite's own configuration verifies against the system's roots |
| `TestTriesAgainAfterAFailedDial` | a failed dial closes the request's body and leaves nothing that stops the next try |
| `TestPlainHTTPGoesThroughDial` | `http:` goes through `dial`, never the environment's proxy |

`go/iptproxy/interop/` runs meek_lite with this file, as the framework
builds it, against meek-server as released. `build.sh check` holds the
modules here to the versions the framework compiles.

Sources and what changed from them: [PROVENANCE.md](PROVENANCE.md).
Licence: [LICENSE](LICENSE).
