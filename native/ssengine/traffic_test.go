package main

import (
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/shadowsocks/go-shadowsocks2/core"
)

type partialTrafficConn struct {
	net.Conn
}

type partialTrafficPacketConn struct {
	net.PacketConn
}

func (partialTrafficConn) Read(p []byte) (int, error) {
	return copy(p, "reply"), io.EOF
}

func (partialTrafficConn) Write([]byte) (int, error) {
	return 3, io.ErrShortWrite
}

func (partialTrafficPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, err := (partialTrafficConn{}).Read(p)
	return n, &net.UDPAddr{}, err
}

func (partialTrafficPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	return (partialTrafficConn{}).Write(p)
}

func TestTrafficCountsPartialTransfersAndPreservesErrors(t *testing.T) {
	counters := &trafficCounters{}
	conn := &meteredConn{Conn: partialTrafficConn{}, counters: counters}
	packet := &meteredPacketConn{PacketConn: partialTrafficPacketConn{}, counters: counters}
	buf := make([]byte, 100)
	if n, err := conn.Read(buf); n != 5 || !errors.Is(err, io.EOF) {
		t.Fatalf("read: %d, %v", n, err)
	}
	if n, err := conn.Write(buf); n != 3 || !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("write: %d, %v", n, err)
	}
	if n, addr, err := packet.ReadFrom(buf); n != 5 || addr == nil || !errors.Is(err, io.EOF) {
		t.Fatalf("read packet: %d, %v, %v", n, addr, err)
	}
	if n, err := packet.WriteTo(buf, &net.UDPAddr{}); n != 3 || !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("write packet: %d, %v", n, err)
	}
	if up, down := counters.uploaded.Load(), counters.downloaded.Load(); up != 6 || down != 10 {
		t.Fatalf("counted requested bytes instead of transferred bytes: up=%d down=%d", up, down)
	}
}

func TestTrafficConcurrentConnections(t *testing.T) {
	counters := &trafficCounters{}
	var workers sync.WaitGroup
	for i := 0; i < 20; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			conn := &meteredConn{Conn: partialTrafficConn{}, counters: counters}
			for j := 0; j < 100; j++ {
				conn.Read(make([]byte, 10))
				conn.Write([]byte("upload"))
			}

		}()
	}
	workers.Wait()
	if up, down := counters.uploaded.Load(), counters.downloaded.Load(); up != 6000 || down != 10000 {
		t.Fatalf("lost concurrent traffic: up=%d down=%d", up, down)
	}
}

func TestTrafficEncryptedUDP(t *testing.T) {
	t.Setenv("SHADOWSOCKS_SF_CAPACITY", "-1")
	client, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	client.SetDeadline(time.Now().Add(3 * time.Second))
	server.SetDeadline(time.Now().Add(3 * time.Second))
	cipher, err := core.PickCipher("aes-256-gcm", nil, "traffic-test")
	if err != nil {
		t.Fatal(err)
	}
	counters := &trafficCounters{}
	client = (meteredCipher{Cipher: cipher, counters: counters}).PacketConn(client)
	if _, err := client.WriteTo([]byte("hello"), server.LocalAddr()); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 1024)
	length, peer, err := server.ReadFrom(buf)
	if err != nil {
		t.Fatal(err)
	}
	if up := counters.uploaded.Load(); up != uint64(length) || up <= 5 {
		t.Fatalf("encrypted UDP upload up=%d, wire=%d", up, length)
	}
	// Echo the encrypted packet to exercise decryption and wire-byte download accounting.
	if _, err := server.WriteTo(buf[:length], peer); err != nil {
		t.Fatal(err)
	}
	n, _, err := client.ReadFrom(buf)
	if err != nil || string(buf[:n]) != "hello" {
		t.Fatalf("encrypted UDP reply: %q, %v", buf[:n], err)
	}
	if down := counters.downloaded.Load(); down != uint64(length) {
		t.Fatalf("encrypted UDP download down=%d, wire=%d", down, length)
	}
}
