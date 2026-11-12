package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/pion/turn/v5"
)

func clientAllocation(t *testing.T, f *fixture, credential string) (*turn.Client, net.PacketConn, error) {
	t.Helper()
	address := fmt.Sprintf("127.0.0.1:%d", f.port)
	conn, err := net.DialTimeout("tcp4", address, 3*time.Second)
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
	f, err := newFixture()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = f.server.Close() })
	if _, _, err := clientAllocation(t, f, "incorrect-synthetic-password"); err == nil {
		t.Fatal("accepted an incorrect credential")
	}
	if f.allocations.Load() != 0 {
		t.Fatal("incorrect credential created a relay")
	}
	aClient, a, err := clientAllocation(t, f, f.password)
	if err != nil {
		t.Fatal(err)
	}
	bClient, b, err := clientAllocation(t, f, f.password)
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
