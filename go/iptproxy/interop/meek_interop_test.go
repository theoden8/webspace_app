// The meek_lite client IPtProxy.xcframework carries, lyrebird's meek_lite with
// go/meekutls's round tripper in place of its GPL transport.go, against
// meek-server as the Tor Project releases it: the server behind a meek
// bridge's front (TOR-016). meek-server serves HTTPS, h2 included, with a
// certificate for the front under a root the client trusts only as it trusts
// any, from the system's roots: TestMain points them at that root alone.
package interop

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	pt "gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/goptlib"
	"gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/transports/meeklite"
)

// A meek_lite line's front and the host behind it, as the app's built-in line
// has them (url=https://<behind> front=<front>).
const (
	meekFront  = "front.example"
	meekBehind = "meek.example"
	// More than one request carries each way (meek's maxPayloadLength).
	meekPayload  = 3*0x10000 + 1234
	meekSessions = 3
)

// tlsDir holds the test root (ca.pem) and the front's certificate under it
// (cert.pem, key.pem).
var tlsDir string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "interop-tls")
	if err == nil {
		err = writePKI(dir)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	tlsDir = dir
	// Before anything reads the system's roots, which crypto/x509 does once.
	os.Setenv("SSL_CERT_FILE", filepath.Join(dir, "ca.pem"))
	os.Setenv("SSL_CERT_DIR", filepath.Join(dir, "no-roots"))
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func TestMeekLiteCrossesUpstreamMeekServer(t *testing.T) {
	bin := upstream(t, "MEEK_SERVER")
	switch runtime.GOOS {
	case "darwin", "ios", "windows":
		t.Skip("crypto/x509 does not read the system's roots from SSL_CERT_FILE here")
	}
	srv := startServer(t, bin, "meek", freeAddr(t),
		"--cert", filepath.Join(tlsDir, "cert.pem"), "--key", filepath.Join(tlsDir, "key.pem"))
	defer srv.stop(t)

	// The built-in line's hello, and Chrome's, which a line with no utls= gets.
	for _, hello := range []string{"HelloRandomizedALPN", ""} {
		for i := 0; i < meekSessions; i++ {
			if err := meekSession(srv, hello); err != nil {
				t.Fatalf("utls=%q, session %d: %v", hello, i, err)
			}
		}
	}
}

// meekSession opens a meek_lite connection to srv through its front and
// sends a payload through the server and its ORPort and back.
func meekSession(srv *server, hello string) error {
	f, err := (&meeklite.Transport{}).ClientFactory("")
	if err != nil {
		return err
	}
	line := pt.Args{"url": {"https://" + meekBehind + "/"}, "front": {meekFront}}
	if hello != "" {
		line["utls"] = []string{hello}
	}
	args, err := f.ParseArgs(&line)
	if err != nil {
		return err
	}
	var mu sync.Mutex
	var dialled []string
	// meek_lite dials the front, not the bridge's address; every name here is
	// the server's.
	conn, err := f.Dial("tcp", "192.0.2.20:80", func(network, addr string) (net.Conn, error) {
		mu.Lock()
		dialled = append(dialled, addr)
		mu.Unlock()
		return net.DialTimeout(network, srv.addr, deadline)
	}, args)
	if err != nil {
		return err
	}
	defer conn.Close()

	payload := make([]byte, meekPayload)
	if _, err := rand.Read(payload); err != nil {
		return err
	}
	back := make([]byte, len(payload))
	read := make(chan error, 1)
	go func() {
		_, err := io.ReadFull(conn, back)
		read <- err
	}()
	if _, err := conn.Write(payload); err != nil {
		return fmt.Errorf("write through the bridge: %w", err)
	}
	select {
	case err := <-read:
		if err != nil {
			return fmt.Errorf("read back through the bridge: %w", err)
		}
	case <-time.After(4 * deadline):
		return fmt.Errorf("nothing came back through the bridge in %s", 4*deadline)
	}
	if !bytes.Equal(back, payload) {
		return fmt.Errorf("the bridge returned other bytes than it was sent")
	}
	mu.Lock()
	defer mu.Unlock()
	for _, addr := range dialled {
		if addr != meekFront+":443" {
			return fmt.Errorf("meek_lite dialled %s, not the front", addr)
		}
	}
	return nil
}

// freeAddr is a loopback address nothing listens on: meek-server cannot take
// port 0.
func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().String()
}

// writePKI writes a root, and a certificate for the front under it, into dir.
func writePKI(dir string) error {
	now := time.Now()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	ca := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "interop test root"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		return err
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		return err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	leaf := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: meekFront},
		DNSNames:     []string{meekFront},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, caCert, &key.PublicKey, caKey)
	if err != nil {
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	for name, block := range map[string]*pem.Block{
		"ca.pem":   {Type: "CERTIFICATE", Bytes: caDER},
		"cert.pem": {Type: "CERTIFICATE", Bytes: leafDER},
		"key.pem":  {Type: "PRIVATE KEY", Bytes: keyDER},
	} {
		if err := os.WriteFile(filepath.Join(dir, name), pem.EncodeToMemory(block), 0o600); err != nil {
			return err
		}
	}
	return os.Mkdir(filepath.Join(dir, "no-roots"), 0o700)
}
