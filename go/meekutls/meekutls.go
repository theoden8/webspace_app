// Copyright (c) 2026 Kirill Rodriguez
// SPDX-License-Identifier: BSD-3-Clause
//
// Adapted from meek-client/utls.go by David Fifield, in meek at commit
// d8ee8e88c5d73ced19c78f884a868114a8421170, which is dedicated to the public
// domain under CC0-1.0. go/meekutls/PROVENANCE.md says what changed.

package meeklite

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"sync"

	utls "github.com/refraction-networking/utls"
	"golang.org/x/net/http2"
)

// newRoundTripper is what meek.go sends meek_lite's requests through when the
// bridge line names a uTLS ClientHello (utls=, Chrome's when it names none):
// every connection is made by dial and its TLS handshake sends
// clientHelloID's hello, and HTTP/2 is spoken where the server chose it.
//
// http.Transport speaks HTTP/2 only over a crypto/tls connection of its own;
// over one from DialTLSContext it speaks HTTP/1.1 whatever the handshake
// chose, and most uTLS hellos offer h2. So the first request to an address
// dials it and reads the protocol the server chose: h2 gets an
// http2.Transport, anything else an http.Transport, and that transport's
// first dial is handed the connection.
func newRoundTripper(dial func(network, addr string) (net.Conn, error), clientHelloID *utls.ClientHelloID) *meekutlsRoundTripper {
	plain := http.DefaultTransport.(*http.Transport).Clone()
	// Every connection goes through dial, which carries the bridge's proxy if
	// it has one; the environment's would take TLS away from uTLS.
	plain.Proxy = nil
	plain.DialContext = func(_ context.Context, network, addr string) (net.Conn, error) {
		return dial(network, addr)
	}
	return &meekutlsRoundTripper{
		dial:          dial,
		clientHelloID: clientHelloID,
		plain:         plain,
		byAddr:        map[string]http.RoundTripper{},
	}
}

type meekutlsRoundTripper struct {
	dial          func(network, addr string) (net.Conn, error)
	clientHelloID *utls.ClientHelloID
	// What each handshake starts from: nil in meek_lite, which verifies the
	// server against the system's roots.
	config *utls.Config
	// Sends http: requests, which take no TLS, and holds the defaults the
	// transports made for https: copy.
	plain *http.Transport

	lock sync.Mutex
	// One per address dialled, since each server chooses its own protocol:
	// meek.go moves on to the next front when one fails.
	byAddr map[string]http.RoundTripper
}

func (rt *meekutlsRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	switch req.URL.Scheme {
	case "http":
		return rt.plain.RoundTrip(req)
	case "https":
	default:
		closeBody(req)
		return nil, fmt.Errorf("meek_lite: unsupported URL scheme %q", req.URL.Scheme)
	}
	port := req.URL.Port()
	if port == "" {
		port = "443"
	}
	addr := net.JoinHostPort(req.URL.Hostname(), port)

	rt.lock.Lock()
	inner, ok := rt.byAddr[addr]
	if !ok {
		var err error
		if inner, err = rt.bootstrap(req.Context(), addr); err != nil {
			rt.lock.Unlock()
			closeBody(req)
			return nil, err
		}
		rt.byAddr[addr] = inner
	}
	rt.lock.Unlock()
	return inner.RoundTrip(req)
}

// bootstrap dials addr and returns the transport for the protocol its server
// chose, whose first dial takes that connection rather than make another.
func (rt *meekutlsRoundTripper) bootstrap(ctx context.Context, addr string) (http.RoundTripper, error) {
	first, err := rt.dialTLS(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	protocol := first.ConnectionState().NegotiatedProtocol

	var lock sync.Mutex
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		lock.Lock()
		taken := first
		first = nil
		lock.Unlock()
		if taken != nil {
			return taken, nil
		}
		conn, err := rt.dialTLS(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		// The transport speaks the first connection's protocol.
		if got := conn.ConnectionState().NegotiatedProtocol; got != protocol {
			_ = conn.Close()
			return nil, fmt.Errorf("meek_lite: %s chose ALPN %q, then %q", addr, protocol, got)
		}
		return conn, nil
	}

	if protocol == http2.NextProtoTLS {
		return &http2.Transport{
			DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
				return dial(ctx, network, addr)
			},
			// Its default keeps an idle connection open for ever, past the
			// meek_lite connection it was made for.
			IdleConnTimeout: rt.plain.IdleConnTimeout,
		}, nil
	}
	tr := rt.plain.Clone()
	tr.DialTLSContext = dial
	return tr, nil
}

// dialTLS dials addr and runs the handshake with the round tripper's hello,
// within the time http.Transport gives its own handshakes.
func (rt *meekutlsRoundTripper) dialTLS(ctx context.Context, network, addr string) (*utls.UConn, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	conn, err := rt.dial(network, addr)
	if err != nil {
		return nil, err
	}
	config := &utls.Config{}
	if rt.config != nil {
		config = rt.config.Clone()
	}
	if config.ServerName == "" {
		// As crypto/tls takes it from the address: the name the certificate
		// is checked against, sent as SNI unless it is an IP address.
		config.ServerName = host
	}
	uconn := utls.UClient(conn, config, *rt.clientHelloID)
	ctx, cancel := context.WithTimeout(ctx, rt.plain.TLSHandshakeTimeout)
	defer cancel()
	if err := uconn.HandshakeContext(ctx); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return uconn, nil
}

// closeBody keeps http.RoundTripper's contract for a request it does not send.
func closeBody(req *http.Request) {
	if req.Body != nil {
		_ = req.Body.Close()
	}
}
