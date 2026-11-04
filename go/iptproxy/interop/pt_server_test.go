// Package interop runs the bridge transports IPtProxy.xcframework carries,
// as go/iptproxy/build.sh prepares them, against the servers bridges run as
// the Tor Project releases them (TOR-016). Each server is a test peer built
// by `go/iptproxy/build.sh upstream` and run as its own process; nothing of
// it reaches the framework.
package interop

import (
	"bufio"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// upstream is the server binary the environment variable names, or a skip
// outside CI.
func upstream(t *testing.T, env string) string {
	t.Helper()
	bin := os.Getenv(env)
	if bin == "" {
		if os.Getenv("CI") == "true" {
			t.Fatalf("%s names no server; go/iptproxy/build.sh upstream builds it", env)
		}
		t.Skipf("%s is unset; go/iptproxy/build.sh upstream builds the server", env)
	}
	return bin
}

type server struct {
	addr   string
	args   string // the SMETHOD line's ARGS, if it has any
	cmd    *exec.Cmd
	stdin  io.Closer
	orPort net.Listener
}

// startServer runs bin as method's server under the managed-transport
// protocol (pt-spec.txt), listening on bindAddr in front of an ORPort that
// echoes, with flags on its command line.
func startServer(t *testing.T, bin, method, bindAddr string, flags ...string) *server {
	t.Helper()
	orPort, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go echo(orPort)

	cmd := exec.Command(bin, flags...)
	cmd.Env = append(os.Environ(),
		"TOR_PT_MANAGED_TRANSPORT_VER=1",
		"TOR_PT_STATE_LOCATION="+t.TempDir(),
		"TOR_PT_SERVER_TRANSPORTS="+method,
		"TOR_PT_SERVER_BINDADDR="+method+"-"+bindAddr,
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
		case fields[0] == "SMETHOD" && len(fields) >= 3 && fields[1] == method:
			srv.addr = fields[2]
			if len(fields) >= 4 {
				srv.args = strings.TrimPrefix(fields[3], "ARGS:")
			}
		case fields[0] == "SMETHODS" && len(fields) == 2 && fields[1] == "DONE":
			if srv.addr == "" {
				t.Fatalf("the server listed no %s bridge", method)
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
