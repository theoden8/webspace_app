// The obfs4 client IPtProxy.xcframework carries, lyrebird's own obfs4 over
// go/hiddenkey's Elligator 2, against lyrebird as the Tor Project releases
// it: the server an obfs4 bridge runs (TOR-016). The server is a test peer
// built by `go/iptproxy/build.sh upstream`, run as its own process; nothing
// of it reaches the framework.
//
// Each of the servers starts with a fresh identity, and each handshake with a
// fresh session key, so the client's representatives take every value of
// their two padding bits (254 and 255): a server that read them would refuse
// some of these handshakes.
package obfs4interop

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
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
	bin := os.Getenv("LYREBIRD_UPSTREAM")
	if bin == "" {
		if os.Getenv("CI") == "true" {
			t.Fatal("LYREBIRD_UPSTREAM names no server; go/iptproxy/build.sh upstream builds it")
		}
		t.Skip("LYREBIRD_UPSTREAM is unset; go/iptproxy/build.sh upstream builds the server")
	}

	// padding[b][v]: handshakes whose representative has bit 254+b equal to v.
	var padding [2][2]int
	for s := 0; s < servers; s++ {
		srv := startServer(t, bin)
		for i := 0; i < perServer; i++ {
			repr, err := handshake(srv)
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

type server struct {
	addr   string
	cert   string
	cmd    *exec.Cmd
	stdin  io.Closer
	orPort net.Listener
}

// startServer runs bin as an obfs4 server under the managed-transport
// protocol (pt-spec.txt), in front of an ORPort that echoes.
func startServer(t *testing.T, bin string) *server {
	t.Helper()
	orPort, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go echo(orPort)

	cmd := exec.Command(bin)
	cmd.Env = append(os.Environ(),
		"TOR_PT_MANAGED_TRANSPORT_VER=1",
		"TOR_PT_STATE_LOCATION="+t.TempDir(),
		"TOR_PT_SERVER_TRANSPORTS=obfs4",
		"TOR_PT_SERVER_BINDADDR=obfs4-127.0.0.1:0",
		"TOR_PT_ORPORT="+orPort.Addr().String(),
		"TOR_PT_EXIT_ON_STDIN_CLOSE=1",
	)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	srv := &server{cmd: cmd, stdin: stdin, orPort: orPort}

	lines := bufio.NewScanner(stdout)
	for lines.Scan() {
		line := lines.Text()
		t.Logf("server: %s", line)
		fields := strings.Fields(line)
		switch {
		case len(fields) == 0:
		case fields[0] == "SMETHOD" && len(fields) >= 4 && fields[1] == "obfs4":
			srv.addr = fields[2]
			srv.cert = smethodArg(t, strings.TrimPrefix(fields[3], "ARGS:"), "cert")
		case fields[0] == "SMETHODS" && len(fields) == 2 && fields[1] == "DONE":
			if srv.addr == "" || srv.cert == "" {
				t.Fatal("the server listed no obfs4 bridge")
			}
			go func() { _, _ = io.Copy(io.Discard, stdout) }()
			return srv
		case strings.HasSuffix(fields[0], "-ERROR"):
			t.Fatalf("the server refused its configuration: %s", line)
		}
	}
	t.Fatalf("the server exited before SMETHODS DONE: %v", lines.Err())
	return nil
}

func (s *server) stop(t *testing.T) {
	t.Helper()
	_ = s.stdin.Close()
	done := make(chan error, 1)
	go func() { done <- s.cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		_ = s.cmd.Process.Kill()
		<-done
	}
	_ = s.orPort.Close()
}

// smethodArg reads key out of an SMETHOD line's ARGS, which escape `,`, `=`
// and `\` with a backslash.
func smethodArg(t *testing.T, args, key string) string {
	t.Helper()
	var pairs []string
	var cur strings.Builder
	for i := 0; i < len(args); i++ {
		switch c := args[i]; {
		case c == '\\' && i+1 < len(args):
			i++
			cur.WriteByte(args[i])
		case c == ',':
			pairs = append(pairs, cur.String())
			cur.Reset()
		default:
			cur.WriteByte(c)
		}
	}
	pairs = append(pairs, cur.String())
	for _, p := range pairs {
		if k, v, ok := strings.Cut(p, "="); ok && k == key {
			return v
		}
	}
	t.Fatalf("SMETHOD ARGS %q carry no %s", args, key)
	return ""
}

func echo(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			_, _ = io.Copy(c, c)
		}()
	}
}

// handshake dials srv with a fresh session key, round-trips a payload
// through the server and its ORPort, and returns the representative the
// client sent: the first 32 bytes of its handshake (obfs4-spec.txt, 4).
func handshake(srv *server) ([32]byte, error) {
	var repr [32]byte
	f, err := (&obfs4.Transport{}).ClientFactory("")
	if err != nil {
		return repr, err
	}
	args, err := f.ParseArgs(&pt.Args{"cert": []string{srv.cert}, "iat-mode": []string{"0"}})
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
