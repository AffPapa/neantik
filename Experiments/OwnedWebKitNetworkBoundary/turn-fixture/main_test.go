package main

import (
	"bytes"
	"context"
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
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/turn/v5"
)

func clientAllocation(t *testing.T, f *fixture, credential string, dial func(string) (net.Conn, error)) (*turn.Client, net.PacketConn, error) {
	t.Helper()
	address := fmt.Sprintf("127.0.0.1:%d", f.port)
	conn, err := dial(address)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	client, err := turn.NewClient(&turn.ClientConfig{
		Conn: turn.NewSTUNConn(conn), TURNServerAddr: address,
		Username: f.username, Password: credential, Realm: realm,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	if err := client.Listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	relay, err := client.AllocateWithContext(ctx)
	if err == nil {
		t.Cleanup(func() { _ = relay.Close() })
		if err := relay.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	return client, relay, err
}

func TestAuthenticatedTCPAllocationsRelayNonce(t *testing.T) {
	f, err := newFixture(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = f.server.Close() })
	checkAuthenticatedAllocations(t, f, func(address string) (net.Conn, error) {
		return net.DialTimeout("tcp4", address, 3*time.Second)
	})
}

func checkAuthenticatedAllocations(t *testing.T, f *fixture, dial func(string) (net.Conn, error)) {
	t.Helper()
	if _, _, err := clientAllocation(t, f, "incorrect-synthetic-password", dial); err == nil {
		t.Fatal("accepted an incorrect credential")
	}
	if f.allocations.Load() != 0 {
		t.Fatal("incorrect credential created a relay")
	}
	aClient, a, err := clientAllocation(t, f, f.password, dial)
	if err != nil {
		t.Fatal(err)
	}
	bClient, b, err := clientAllocation(t, f, f.password, dial)
	if err != nil {
		t.Fatal(err)
	}
	if a.LocalAddr().String() == b.LocalAddr().String() || f.allocations.Load() != 2 {
		t.Fatal("expected two independent relay allocations")
	}
	for _, relay := range []net.PacketConn{a, b} {
		addr, ok := relay.LocalAddr().(*net.UDPAddr)
		if !ok || !addr.IP.Equal(net.IPv4(127, 0, 0, 1)) {
			t.Fatal("relay endpoint is outside the fixture")
		}
	}
	// This requests permission over the local control connection. It does
	// not send a datagram to the reserved documentation address.
	if err := aClient.CreatePermission(&net.UDPAddr{IP: net.IPv4(192, 0, 2, 1), Port: 49152}); err == nil {
		t.Fatal("fixture accepted a non-loopback peer")
	}
	// Establish B's permission first, then send a random nonce across the
	// relay pair. A successful allocation alone would miss a broken data path.
	if err := bClient.CreatePermission(a.LocalAddr()); err != nil {
		t.Fatal(err)
	}
	var nonce, received [32]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		t.Fatal(err)
	}
	if _, err := a.WriteTo(nonce[:], b.LocalAddr()); err != nil {
		t.Fatal(err)
	}
	n, from, err := b.ReadFrom(received[:])
	if err != nil || n != len(nonce) || !bytes.Equal(nonce[:], received[:]) ||
		from.String() != a.LocalAddr().String() {
		t.Fatalf("relay failed to deliver nonce: received %d bytes, error %v", n, err)
	}
}

func testChain(t *testing.T, aiaURL string) (tls.Certificate, *x509.Certificate) {
	t.Helper()
	now := time.Now()
	issue := func(serial int64, name string, ca bool, issuer *x509.Certificate, signer *ecdsa.PrivateKey) (*x509.Certificate, *ecdsa.PrivateKey) {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		certificate := &x509.Certificate{
			SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: name},
			NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
			BasicConstraintsValid: true, IsCA: ca,
			KeyUsage: x509.KeyUsageDigitalSignature,
		}
		if ca {
			certificate.KeyUsage = x509.KeyUsageCertSign
		} else {
			certificate.DNSNames = []string{name}
			if aiaURL != "" {
				certificate.IssuingCertificateURL = []string{aiaURL}
			}
			certificate.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		}
		if issuer == nil {
			issuer, signer = certificate, key
		}
		der, err := x509.CreateCertificate(rand.Reader, certificate, issuer, &key.PublicKey, signer)
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := x509.ParseCertificate(der)
		if err != nil {
			t.Fatal(err)
		}
		return parsed, key
	}
	root, rootKey := issue(1, "NeAntik test root", true, nil, nil)
	intermediate, intermediateKey := issue(2, "NeAntik test intermediate", true, root, rootKey)
	leaf, key := issue(3, "turn-neantik.invalid", false, intermediate, intermediateKey)
	return tls.Certificate{Certificate: [][]byte{leaf.Raw, intermediate.Raw}, PrivateKey: key}, root
}

func TestTLSAllocationsAndCertificateRejection(t *testing.T) {
	chain, root := testChain(t, "")
	roots := x509.NewCertPool()
	roots.AddCert(root)
	client := func(host string) func(string) (net.Conn, error) {
		return func(address string) (net.Conn, error) {
			connection, err := tls.DialWithDialer(&net.Dialer{Timeout: 3 * time.Second}, "tcp4", address,
				&tls.Config{RootCAs: roots, ServerName: host, MinVersion: tls.VersionTLS12})
			if err != nil {
				return nil, err
			}
			return connection, nil
		}
	}
	listen := func(t *testing.T, cert tls.Certificate) *fixture {
		t.Helper()
		f, err := newFixture(&cert)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = f.server.Close() })
		return f
	}
	t.Run("complete chain and data relay", func(t *testing.T) {
		checkAuthenticatedAllocations(t, listen(t, chain), client("turn-neantik.invalid"))
	})
	t.Run("wrong hostname", func(t *testing.T) {
		f := listen(t, chain)
		connection, err := client("wrong-neantik.invalid")(fmt.Sprintf("127.0.0.1:%d", f.port))
		if connection != nil {
			_ = connection.Close()
		}
		var hostnameError x509.HostnameError
		if !errors.As(err, &hostnameError) || f.allocations.Load() != 0 {
			t.Fatalf("expected hostname rejection before any allocation, got %v", err)
		}
	})
	t.Run("missing intermediate", func(t *testing.T) {
		incomplete := chain
		incomplete.Certificate = incomplete.Certificate[:1]
		f := listen(t, incomplete)
		connection, err := client("turn-neantik.invalid")(fmt.Sprintf("127.0.0.1:%d", f.port))
		if connection != nil {
			_ = connection.Close()
		}
		var authorityError x509.UnknownAuthorityError
		if !errors.As(err, &authorityError) || f.allocations.Load() != 0 {
			t.Fatalf("expected incomplete-chain rejection before any allocation, got %v", err)
		}
	})
}

// This exercises Apple's TLS verify callback with a real TURN/TLS listener.
// Each case gets a fresh intermediate, so trustd cannot supply one cached
// from the positive case. The HTTP control serves only fixture DER bytes.
func TestNativeTLSCallbackAndAIA(t *testing.T) {
	probe := os.Getenv("NEANTIK_NATIVE_TURN_TLS_PROBE")
	if probe == "" {
		t.Skip("explicit macOS trust probe executable required")
	}
	if !filepath.IsAbs(probe) {
		t.Fatal("probe executable must use an absolute path")
	}
	for _, tc := range []struct {
		name, hostname, outcome string
		includeIntermediate     bool
	}{
		{"complete chain", "turn-neantik.invalid", "binding-verified", true},
		{"wrong hostname", "wrong-neantik.invalid", "trust-rejected", true},
		{"missing intermediate", "turn-neantik.invalid", "trust-rejected", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var requests atomic.Int64
			var issuer atomic.Value
			const path = "/issuer.der"
			aia := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				if r.Method != http.MethodGet || r.URL.Path != path {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "application/pkix-cert")
				_, _ = w.Write(issuer.Load().([]byte))
			}))
			defer aia.Close()
			chain, root := testChain(t, aia.URL+path)
			issuer.Store(chain.Certificate[1])

			// Confirm the embedded URL actually serves the missing certificate.
			httpClient := http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{}}
			defer httpClient.CloseIdleConnections()
			res, err := httpClient.Get(aia.URL + path)
			if err != nil {
				t.Fatal(err)
			}
			got, err := io.ReadAll(res.Body)
			_ = res.Body.Close()
			if err != nil || res.StatusCode != http.StatusOK || !bytes.Equal(got, chain.Certificate[1]) || requests.Load() != 1 {
				t.Fatal("AIA listener did not return the intermediate")
			}

			if !tc.includeIntermediate {
				chain.Certificate = chain.Certificate[:1]
			}
			server, err := newFixture(&chain)
			if err != nil {
				t.Fatal(err)
			}
			defer server.server.Close()
			anchor := filepath.Join(t.TempDir(), "root.der")
			if err := os.WriteFile(anchor, root.Raw, 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			output, err := exec.CommandContext(ctx, probe, fmt.Sprint(server.port), tc.hostname, anchor).Output()
			if err != nil || strings.TrimSpace(string(output)) != tc.outcome {
				t.Fatalf("unexpected native trust outcome: %q, %v", output, err)
			}
			if server.tcpAccepts.Load() != 1 || server.allocations.Load() != 0 || requests.Load() != 1 {
				t.Fatal("expected one TLS accept, zero allocations and no additional AIA request")
			}
			deadline := time.Now().Add(time.Second)
			for server.tlsAccepted.Load()+server.tlsRejected.Load()+server.tlsOther.Load() == 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if tc.outcome == "binding-verified" {
				if server.tlsAccepted.Load() != 1 || server.tlsRejected.Load() != 0 || server.tlsOther.Load() != 0 {
					t.Fatal("valid chain did not record one accepted handshake")
				}
			} else if server.tlsAccepted.Load() != 0 || server.tlsRejected.Load() != 1 || server.tlsOther.Load() != 0 {
				t.Fatal("trust rejection did not record the peer's certificate alert")
			}
		})
	}
}
