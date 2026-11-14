// Private loopback TURN control for the owned-WebKit network tests.
package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/pion/turn/v5"
)

const realm = "neantik-turn-fixture.invalid"

type fixture struct {
	server      *turn.Server
	port        int
	username    string
	password    string
	allocations atomic.Uint64
	tcpAccepts  atomic.Uint64
	tlsAccepted atomic.Uint64
	tlsRejected atomic.Uint64
	tlsOther    atomic.Uint64
}

type countingListener struct {
	net.Listener
	accepted *atomic.Uint64
}

func (l countingListener) Accept() (net.Conn, error) {
	connection, err := l.Listener.Accept()
	if err == nil {
		l.accepted.Add(1)
	}
	return connection, err
}

type observedTLSListener struct {
	net.Listener
	fixture *fixture
}

func (l observedTLSListener) Accept() (net.Conn, error) {
	connection, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &observedTLSConnection{Conn: connection.(*tls.Conn), fixture: l.fixture}, nil
}

type observedTLSConnection struct {
	*tls.Conn
	fixture   *fixture
	handshake sync.Once
	err       error
}

func (c *observedTLSConnection) Read(data []byte) (int, error) {
	c.handshake.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		c.err = c.HandshakeContext(ctx)
		switch {
		case c.err == nil:
			c.fixture.tlsAccepted.Add(1)
		case isRemoteCertificateAlert(c.err):
			c.fixture.tlsRejected.Add(1)
		default:
			c.fixture.tlsOther.Add(1)
		}
	})
	if c.err != nil {
		return 0, c.err
	}
	return c.Conn.Read(data)
}

// Go's TCP TLS implementation wraps the peer's alert in net.OpError.
// Compare the standard alert names without recording error strings or peers.
func isRemoteCertificateAlert(err error) bool {
	var remote *net.OpError
	if !errors.As(err, &remote) || remote.Op != "remote error" {
		return false
	}
	for _, alert := range []tls.AlertError{42, 43, 44, 45, 46, 48} {
		if remote.Err.Error() == alert.Error() {
			return true
		}
	}
	return false
}

// TCP is the client-to-TURN transport. WebRTC still uses UDP relay endpoints.
// Disable RFC 6062 TCP relay, including any server-side outbound TCP dial.
type udpRelay struct {
	turn.RelayAddressGeneratorStatic
}

func (udpRelay) AllocateListener(turn.AllocateListenerConfig) (net.Listener, net.Addr, error) {
	return nil, nil, errors.New("TCP relay disabled")
}

func (udpRelay) AllocateConn(turn.AllocateConnConfig) (net.Conn, error) {
	return nil, errors.New("TCP relay disabled")
}

func newFixture(certificate *tls.Certificate) (*fixture, error) {
	var secret [32]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	f := &fixture{
		port:     listener.Addr().(*net.TCPAddr).Port,
		username: "neantik-fixture",
		password: hex.EncodeToString(secret[:]),
	}
	var transport net.Listener = countingListener{Listener: listener, accepted: &f.tcpAccepts}
	if certificate != nil {
		transport = observedTLSListener{Listener: tls.NewListener(transport, &tls.Config{
			Certificates: []tls.Certificate{*certificate},
			MinVersion:   tls.VersionTLS12,
		}), fixture: f}
	}
	key := turn.GenerateAuthKey(f.username, realm, f.password)
	server, err := turn.NewServer(turn.ServerConfig{
		Realm:              realm,
		AllocationLifetime: 90 * time.Second,
		AuthHandler: func(r *turn.RequestAttributes) (string, []byte, bool) {
			if r.Username != f.username || r.Realm != realm {
				return "", nil, false
			}
			return f.username, key, true
		},
		EventHandler: turn.EventHandler{
			OnAllocationCreated: func(_, _ net.Addr, _, _, _ string, _ net.Addr, _ int) {
				f.allocations.Add(1)
			},
		},
		ListenerConfigs: []turn.ListenerConfig{{
			Listener: transport,
			RelayAddressGenerator: &udpRelay{turn.RelayAddressGeneratorStatic{
				RelayAddress: net.IPv4(127, 0, 0, 1),
				Address:      "127.0.0.1",
			}},
			PermissionHandler: func(_ net.Addr, peer net.IP) bool {
				return peer.Equal(net.IPv4(127, 0, 0, 1))
			},
		}},
	})
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	f.server = server
	return f, nil
}

func writeReady(file *os.File, f *fixture) error {
	return json.NewEncoder(file).Encode(map[string]any{
		"host": "127.0.0.1", "port": f.port,
		"username": f.username, "credential": f.password, "realm": realm,
	})
}

func run(path, certificateName, keyName string) error {
	if path == "" {
		return errors.New("private ready file is required")
	}
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		return err
	}
	owner, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != uint32(os.Geteuid()) || !parent.IsDir() || parent.Mode().Perm() != 0700 {
		return errors.New("ready file requires an owner-only fixture directory")
	}
	var certificate *tls.Certificate
	if certificateName != "" || keyName != "" {
		directory := filepath.Dir(path)
		for _, name := range []string{certificateName, keyName} {
			if name == "" || name == "." || name == ".." || filepath.Base(name) != name {
				return errors.New("TLS requires certificate and key filenames in the fixture directory")
			}
			file, err := os.Lstat(filepath.Join(directory, name))
			if err != nil || !file.Mode().IsRegular() || file.Mode().Perm() != 0600 {
				return errors.New("TLS fixture files must be private regular files")
			}
		}
		loaded, err := tls.LoadX509KeyPair(filepath.Join(directory, certificateName), filepath.Join(directory, keyName))
		if err != nil {
			return errors.New("invalid fixture TLS certificate or key")
		}
		certificate = &loaded
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(stop)
	f, err := newFixture(certificate)
	if err != nil {
		return err
	}
	defer f.server.Close()

	// An exclusive owner-only handoff keeps the synthetic credential out of
	// the process arguments and terminal output.
	ready, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer os.Remove(path)
	err = writeReady(ready, f)
	if closeErr := ready.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	events := json.NewEncoder(os.Stdout)
	if err := events.Encode(map[string]string{"status": "ready"}); err != nil {
		return err
	}
	<-stop
	counts := map[string]uint64{"allocations": f.allocations.Load(), "tcpAccepts": f.tcpAccepts.Load()}
	if certificate != nil {
		counts["tlsAccepted"] = f.tlsAccepted.Load()
		counts["tlsCertificateRejected"] = f.tlsRejected.Load()
		counts["tlsOtherFailure"] = f.tlsOther.Load()
	}
	return events.Encode(counts)
}

func main() {
	path := flag.String("ready-file", "", "new owner-only JSON handoff in the disposable fixture")
	certificate := flag.String("tls-cert", "", "optional private PEM chain filename in the fixture directory")
	key := flag.String("tls-key", "", "optional private PEM key filename in the fixture directory")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "unexpected fixture arguments")
		os.Exit(2)
	}
	if err := run(*path, *certificate, *key); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
