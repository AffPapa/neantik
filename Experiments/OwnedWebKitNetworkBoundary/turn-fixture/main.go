// Private loopback TURN control for the owned-WebKit network tests.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
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

func newFixture() (*fixture, error) {
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
			Listener: listener,
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

func run(path string) error {
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
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(stop)
	f, err := newFixture()
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
	return events.Encode(map[string]uint64{"allocations": f.allocations.Load()})
}

func main() {
	path := flag.String("ready-file", "", "new owner-only JSON handoff in the disposable fixture")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "unexpected fixture arguments")
		os.Exit(2)
	}
	if err := run(*path); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
