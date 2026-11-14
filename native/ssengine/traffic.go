package main

import (
	"net"
	"sync/atomic"

	"github.com/shadowsocks/go-shadowsocks2/core"
)

type trafficCounters struct {
	uploaded   atomic.Uint64
	downloaded atomic.Uint64
}

var clientTraffic trafficCounters

// Count below encryption so only bytes exchanged with the SS server are included.
type meteredCipher struct {
	core.Cipher
	counters *trafficCounters
}

func (c meteredCipher) StreamConn(conn net.Conn) net.Conn {
	return c.Cipher.StreamConn(&meteredConn{Conn: conn, counters: c.counters})
}

func (c meteredCipher) PacketConn(conn net.PacketConn) net.PacketConn {
	return c.Cipher.PacketConn(&meteredPacketConn{PacketConn: conn, counters: c.counters})
}

type meteredConn struct {
	net.Conn
	counters *trafficCounters
}

func (c *meteredConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.counters.downloaded.Add(uint64(n))
	return n, err
}

func (c *meteredConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.counters.uploaded.Add(uint64(n))
	return n, err
}

type meteredPacketConn struct {
	net.PacketConn
	counters *trafficCounters
}

func (c *meteredPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, addr, err := c.PacketConn.ReadFrom(p)
	c.counters.downloaded.Add(uint64(n))
	return n, addr, err
}

func (c *meteredPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	n, err := c.PacketConn.WriteTo(p, addr)
	c.counters.uploaded.Add(uint64(n))
	return n, err
}
