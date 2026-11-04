package meeklite

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	utls "github.com/refraction-networking/utls"
)

// A meek_lite line's front and the host behind it (url=https://meek.example
// front=front.example): meek.go sends each request to the front, with the
// host behind it in the Host header.
const (
	front  = "front.example"
	behind = "meek.example"
)

// The two hellos the app's bridges send: its built-in line's, and the one
// meek_lite takes when a line names none.
var hellos = []struct {
	name string
	id   *utls.ClientHelloID
}{
	{"HelloRandomizedALPN", &utls.HelloRandomizedALPN},
	{"HelloChrome_Auto", &utls.HelloChrome_Auto},
}

func TestMain(m *testing.M) {
	// A transport that read the environment's proxy would send its requests
	// there, with crypto/tls doing the handshake; this one refuses them all.
	for _, k := range []string{"HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"} {
		os.Setenv(k, "http://127.0.0.1:9")
	}
	os.Unsetenv("NO_PROXY")
	os.Unsetenv("no_proxy")
	os.Exit(m.Run())
}

// Each request is sent with uTLS in the server's protocol, h2 or HTTP/1.1,
// over the connection the first request opened.
func TestRoundTripSpeaksTheProtocolTheServerChose(t *testing.T) {
	pki := newPKI(t)
	for _, hello := range hellos {
		for _, h2 := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/h2=%v", hello.name, h2), func(t *testing.T) {
				// A randomized hello differs on every connection.
				for round := 0; round < 4; round++ {
					srv := startServer(t, pki, h2)
					rt := newRoundTripper(srv.dial, hello.id)
					rt.config = &utls.Config{RootCAs: pki.roots}
					for i := 0; i < 3; i++ {
						srv.post(t, rt, fmt.Sprintf("request %d", i), h2)
					}
					if got := srv.conns(); got != 1 {
						t.Errorf("%d connections for three requests; the first one's was not kept", got)
					}
					srv.checkHellos(t, hello.id)
					srv.Close()
				}
			})
		}
	}
}

// Connections made after the first are uTLS too, and in the same protocol.
func TestLaterConnectionsSpeakTheSameProtocol(t *testing.T) {
	pki := newPKI(t)
	for _, hello := range hellos {
		for _, h2 := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/h2=%v", hello.name, h2), func(t *testing.T) {
				const concurrent = 3
				srv := startServer(t, pki, h2)
				defer srv.Close()
				// No response leaves until every request has arrived, so
				// HTTP/1.1 needs a connection for each.
				srv.barrier(concurrent)
				rt := newRoundTripper(srv.dial, hello.id)
				rt.config = &utls.Config{RootCAs: pki.roots}
				var wg sync.WaitGroup
				for i := 0; i < concurrent; i++ {
					wg.Add(1)
					go func() {
						defer wg.Done()
						srv.post(t, rt, fmt.Sprintf("request %d", i), h2)
					}()
				}
				wg.Wait()
				want := concurrent
				if h2 {
					want = 1
				}
				if got := srv.conns(); got != want {
					t.Errorf("%d connections, want %d", got, want)
				}
				srv.checkHellos(t, hello.id)
			})
		}
	}
}

// A server that chooses another protocol on a later connection is refused
// there, rather than spoken to in the first one's.
func TestRefusesAProtocolSwitch(t *testing.T) {
	pki := newPKI(t)
	srv := startServer(t, pki, true)
	defer srv.Close()
	srv.offerFirst([]string{"http/1.1"})
	srv.barrier(2)
	rt := newRoundTripper(srv.dial, &utls.HelloChrome_Auto)
	rt.config = &utls.Config{RootCAs: pki.roots}

	first := make(chan error, 1)
	go func() {
		resp, err := rt.RoundTrip(request(t, "first"))
		if err == nil {
			resp.Body.Close()
		}
		first <- err
	}()
	srv.waitArrival(t)
	_, err := rt.RoundTrip(request(t, "second"))
	if err == nil || !strings.Contains(err.Error(), `chose ALPN "http/1.1", then "h2"`) {
		t.Errorf("a connection that switched to h2 gave %v", err)
	}
	srv.release()
	if err := <-first; err != nil {
		t.Errorf("the first request: %v", err)
	}
}

// meek_lite's own configuration, which verifies against the system's roots:
// they do not hold the test's.
func TestRefusesACertificateItCannotVerify(t *testing.T) {
	pki := newPKI(t)
	for _, hello := range hellos {
		srv := startServer(t, pki, true)
		rt := newRoundTripper(srv.dial, hello.id)
		_, err := rt.RoundTrip(request(t, "untrusted"))
		var unverified *utls.CertificateVerificationError
		if !errors.As(err, &unverified) {
			t.Errorf("%s: a server under an unknown root gave %v", hello.name, err)
		}
		srv.Close()
	}
}

// A failed first dial leaves nothing behind: meek.go tries again.
func TestTriesAgainAfterAFailedDial(t *testing.T) {
	pki := newPKI(t)
	srv := startServer(t, pki, true)
	defer srv.Close()
	failed := false
	dial := func(network, addr string) (net.Conn, error) {
		if !failed {
			failed = true
			return nil, errors.New("unreachable")
		}
		return srv.dial(network, addr)
	}
	rt := newRoundTripper(dial, &utls.HelloChrome_Auto)
	rt.config = &utls.Config{RootCAs: pki.roots}
	body := &closeRecorder{Reader: strings.NewReader("lost")}
	req := request(t, "")
	req.Body = body
	if _, err := rt.RoundTrip(req); err == nil {
		t.Fatal("a dial that failed gave a response")
	}
	if !body.closed {
		t.Error("the request that was not sent kept its body open")
	}
	srv.post(t, rt, "again", true)
}

// http: URLs take no TLS, and go through dial as well.
func TestPlainHTTPGoesThroughDial(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(w, r.Body)
	}))
	defer srv.Close()
	dialled := 0
	rt := newRoundTripper(func(network, addr string) (net.Conn, error) {
		dialled++
		return net.Dial(network, srv.Listener.Addr().String())
	}, &utls.HelloChrome_Auto)
	req, err := http.NewRequest("POST", "http://"+behind+"/", strings.NewReader("plain"))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := rt.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if got, _ := io.ReadAll(resp.Body); string(got) != "plain" || dialled != 1 {
		t.Errorf("got %q after %d dials", got, dialled)
	}
}

type testPKI struct {
	roots *x509.CertPool
	leaf  tls.Certificate
}

// newPKI makes a root and, under it, a certificate for the front.
func newPKI(t *testing.T) testPKI {
	t.Helper()
	now := time.Now()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "meekutls test root"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: front},
		DNSNames:     []string{front},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, caCert, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(caCert)
	return testPKI{roots: roots, leaf: tls.Certificate{Certificate: [][]byte{leafDER}, PrivateKey: key}}
}

// A TLS server that echoes each request's body, recording the hellos it
// was sent, the connections it took and the addresses dialled for it.
type testServer struct {
	*httptest.Server

	mu       sync.Mutex
	hellos   []seenHello
	accepted int
	dialled  []string
	first    []string // ALPN offered on the first connection only
	gate     *gate
	arrived  int
}

type seenHello struct {
	serverName string
	protos     []string
	suites     []uint16
}

// gate holds each request until want have arrived or it is released, for
// at most a while: a request that never arrives fails the others rather than
// hang the test.
type gate struct {
	want     int
	arrivals chan struct{}
	open     chan struct{}
	once     sync.Once
}

func (g *gate) release() {
	g.once.Do(func() { close(g.open) })
}

func startServer(t *testing.T, pki testPKI, h2 bool) *testServer {
	t.Helper()
	s := &testServer{}
	s.Server = httptest.NewUnstartedServer(http.HandlerFunc(s.serve))
	s.EnableHTTP2 = h2
	// Both protocols where h2 is on, as a real front offers them.
	protos := []string{"http/1.1"}
	if h2 {
		protos = []string{"h2", "http/1.1"}
	}
	s.TLS = &tls.Config{
		Certificates: []tls.Certificate{pki.leaf},
		NextProtos:   protos,
		// Not X25519MLKEM768, which a Go server prefers so much that it asks
		// again for a share of it (a HelloRetryRequest) when a hello lists it
		// without one, as some randomized hellos do; uTLS cannot answer that
		// request, and meek.go's retries are what get past it.
		CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384},
	}
	s.TLS.GetConfigForClient = func(ch *tls.ClientHelloInfo) (*tls.Config, error) {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.hellos = append(s.hellos, seenHello{
			serverName: ch.ServerName,
			protos:     slices.Clone(ch.SupportedProtos),
			suites:     slices.Clone(ch.CipherSuites),
		})
		if s.first != nil && len(s.hellos) == 1 {
			c := s.TLS.Clone()
			c.GetConfigForClient = nil
			c.NextProtos = s.first
			return c, nil
		}
		return nil, nil
	}
	s.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			s.mu.Lock()
			s.accepted++
			s.mu.Unlock()
		}
	}
	s.StartTLS()
	return s
}

func (s *testServer) offerFirst(protos []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.first = protos
}

const gateWait = 10 * time.Second

func (s *testServer) barrier(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gate = &gate{want: n, arrivals: make(chan struct{}, n), open: make(chan struct{})}
}

func (s *testServer) waitArrival(t *testing.T) {
	t.Helper()
	select {
	case <-s.gate.arrivals:
	case <-time.After(gateWait):
		t.Fatal("no request arrived")
	}
}

func (s *testServer) release() {
	s.gate.release()
}

func (s *testServer) serve(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	g := s.gate
	s.arrived++
	arrived := s.arrived
	s.mu.Unlock()
	if g != nil {
		if arrived >= g.want {
			g.release()
		}
		select {
		case g.arrivals <- struct{}{}:
		default:
		}
		select {
		case <-g.open:
		case <-time.After(gateWait):
			http.Error(w, "the other requests never arrived", http.StatusGatewayTimeout)
			return
		}
	}
	w.Header().Set("X-Proto", r.Proto)
	w.Header().Set("X-Alpn", r.TLS.NegotiatedProtocol)
	w.Header().Set("X-Host", r.Host)
	_, _ = w.Write(body)
}

// dial is meek_lite's dialFn, here reaching the server whatever it is asked.
func (s *testServer) dial(network, addr string) (net.Conn, error) {
	s.mu.Lock()
	s.dialled = append(s.dialled, addr)
	s.mu.Unlock()
	return net.Dial(network, s.Listener.Addr().String())
}

func (s *testServer) conns() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.accepted
}

func request(t *testing.T, body string) *http.Request {
	t.Helper()
	req, err := http.NewRequest("POST", "https://"+front+"/", strings.NewReader(body))
	if err != nil {
		t.Error(err)
		return nil
	}
	req.Host = behind
	return req
}

// post sends body as meek.go sends a request and checks what came back.
func (s *testServer) post(t *testing.T, rt http.RoundTripper, body string, h2 bool) {
	t.Helper()
	resp, err := rt.RoundTrip(request(t, body))
	if err != nil {
		t.Errorf("%q: %v", body, err)
		return
	}
	defer resp.Body.Close()
	got, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Errorf("%q: %v", body, err)
		return
	}
	proto, alpn := "HTTP/1.1", "http/1.1"
	if h2 {
		proto, alpn = "HTTP/2.0", "h2"
	}
	switch {
	case resp.StatusCode != http.StatusOK:
		t.Errorf("%q: status %d", body, resp.StatusCode)
	case !bytes.Equal(got, []byte(body)):
		t.Errorf("sent %q, got back %q", body, got)
	case resp.Proto != proto || resp.Header.Get("X-Proto") != proto:
		t.Errorf("%q went as %s, came back as %s; want %s", body, resp.Header.Get("X-Proto"), resp.Proto, proto)
	case resp.Header.Get("X-Alpn") != alpn:
		t.Errorf("%q: the server chose ALPN %q, want %q", body, resp.Header.Get("X-Alpn"), alpn)
	case resp.Header.Get("X-Host") != behind:
		t.Errorf("%q reached %q, not the host behind the front", body, resp.Header.Get("X-Host"))
	}
}

// checkHellos holds every connection to the front's name, offering both
// protocols, and a Chrome hello to Chrome's GREASE, which crypto/tls never
// sends.
func (s *testServer) checkHellos(t *testing.T, id *utls.ClientHelloID) {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, addr := range s.dialled {
		if addr != front+":443" {
			t.Errorf("dialled %s, not the front", addr)
		}
	}
	if len(s.hellos) == 0 {
		t.Error("the server saw no hello")
	}
	for i, h := range s.hellos {
		if h.serverName != front {
			t.Errorf("hello %d named %q, not the front", i, h.serverName)
		}
		if !slices.Contains(h.protos, "h2") || !slices.Contains(h.protos, "http/1.1") {
			t.Errorf("hello %d offered %q", i, h.protos)
		}
		if id.Client == utls.HelloChrome_Auto.Client && !slices.ContainsFunc(h.suites, grease) {
			t.Errorf("hello %d carried no GREASE suite: not Chrome's (%04x)", i, h.suites)
		}
	}
}

// grease is RFC 8701's reserved values, 0x0a0a to 0xfafa.
func grease(v uint16) bool {
	return v&0x0f0f == 0x0a0a && v>>8 == v&0xff
}

type closeRecorder struct {
	io.Reader
	closed bool
}

func (c *closeRecorder) Close() error {
	c.closed = true
	return nil
}
