// The obfs4 client IPtProxy.xcframework carries, lyrebird's own obfs4 over
// go/hiddenkey's Elligator 2, against lyrebird as the Tor Project releases
// it: the server an obfs4 bridge runs (TOR-016).
//
// Each of the servers starts with a fresh identity, and each handshake with a
// fresh session key, so the client's representatives take every value of
// their two padding bits (254 and 255): a server that read them would refuse
// some of these handshakes.
package interop

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"io"
	"net"
	"testing"
	"time"

	pt "gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/goptlib"
	"gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/transports/obfs4"
)

const (
	servers    = 4
	perServer  = 64
	payloadLen = 4096
	deadline   = 30 * time.Second
)

func TestObfs4HandshakesWithUpstreamLyrebird(t *testing.T) {
	bin := upstream(t, "LYREBIRD_UPSTREAM")

	// padding[b][v]: handshakes whose representative has bit 254+b equal to v.
	var padding [2][2]int
	for s := 0; s < servers; s++ {
		srv := startServer(t, bin, "obfs4", "127.0.0.1:0")
		cert := smethodArg(t, srv.args, "cert")
		for i := 0; i < perServer; i++ {
			repr, err := handshake(srv, cert)
			if err != nil {
				t.Fatalf("server %d, handshake %d: %v", s, i, err)
			}
			padding[0][repr[31]>>6&1]++
			padding[1][repr[31]>>7&1]++
		}
		srv.stop(t)
	}
	t.Logf("%d handshakes; bit 254 clear/set %v, bit 255 clear/set %v",
		servers*perServer, padding[0], padding[1])
	for b, seen := range padding {
		if seen[0] == 0 || seen[1] == 0 {
			t.Errorf("no handshake sent bit %d both clear and set (%v): the server's "+
				"acceptance of either is untested", 254+b, seen)
		}
	}
}

// handshake dials srv with a fresh session key, round-trips a payload
// through the server and its ORPort, and returns the representative the
// client sent: the first 32 bytes of its handshake (obfs4-spec.txt, 4).
func handshake(srv *server, cert string) ([32]byte, error) {
	var repr [32]byte
	f, err := (&obfs4.Transport{}).ClientFactory("")
	if err != nil {
		return repr, err
	}
	args, err := f.ParseArgs(&pt.Args{"cert": []string{cert}, "iat-mode": []string{"0"}})
	if err != nil {
		return repr, err
	}
	var sent *recorder
	conn, err := f.Dial("tcp", srv.addr, func(network, addr string) (net.Conn, error) {
		c, err := net.DialTimeout(network, addr, deadline)
		if err != nil {
			return nil, err
		}
		if err := c.SetDeadline(time.Now().Add(deadline)); err != nil {
			c.Close()
			return nil, err
		}
		sent = &recorder{Conn: c}
		return sent, nil
	}, args)
	if err != nil {
		return repr, fmt.Errorf("the handshake failed: %w", err)
	}
	defer conn.Close()
	if len(sent.first) < len(repr) {
		return repr, fmt.Errorf("the client's handshake was %d bytes", len(sent.first))
	}
	copy(repr[:], sent.first)

	payload := make([]byte, payloadLen)
	if _, err := rand.Read(payload); err != nil {
		return repr, err
	}
	if _, err := conn.Write(payload); err != nil {
		return repr, fmt.Errorf("write through the bridge: %w", err)
	}
	back := make([]byte, payloadLen)
	if _, err := io.ReadFull(conn, back); err != nil {
		return repr, fmt.Errorf("read back through the bridge: %w", err)
	}
	if !bytes.Equal(back, payload) {
		return repr, fmt.Errorf("the bridge returned other bytes than it was sent")
	}
	return repr, nil
}

// recorder keeps the start of the first write through it: the client's
// handshake, which obfs4 sends in one write.
type recorder struct {
	net.Conn
	first []byte
}

func (r *recorder) Write(b []byte) (int, error) {
	if r.first == nil {
		r.first = append([]byte{}, b[:min(len(b), 32)]...)
	}
	return r.Conn.Write(b)
}
