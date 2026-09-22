package main

import (
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/shadowsocks/go-shadowsocks2/socks"
)

type udpRouteSession struct {
	connection net.PacketConn
	remote     net.Addr
	header     socks.Addr
	proxy      bool
}

type udpRouter struct {
	sync.Mutex
	sessions map[string]*udpRouteSession
}

func (router *udpRouter) send(listener *net.UDPConn, peer netip.AddrPort, packet []byte, server net.Addr, shadow func(net.PacketConn) net.PacketConn) error {
	if len(packet) < 4 || packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
		return fmt.Errorf("invalid SOCKS UDP frame")
	}
	original := socks.SplitAddr(packet[3:])
	if original == nil {
		return fmt.Errorf("invalid SOCKS UDP address")
	}
	target, proxy, err := routeDestination(original.String())
	if err != nil {
		return err
	}
	key := fmt.Sprintf("%s|%s|%s|%t", peer, original.String(), target, proxy)
	router.Lock()
	defer router.Unlock()
	session := router.sessions[key]
	if session == nil {
		if len(router.sessions) >= 512 {
			return fmt.Errorf("UDP route session limit reached")
		}
		remote := server
		if !proxy {
			remote, err = net.ResolveUDPAddr("udp", target)
			if err != nil {
				return err
			}
		}
		connection, err := net.ListenPacket("udp", "")
		if err != nil {
			return err
		}
		if proxy {
			connection = shadow(connection)
		}
		session = &udpRouteSession{connection: connection, remote: remote, header: socks.ParseAddr(target), proxy: proxy}
		router.sessions[key] = session
		logf("route UDP proxy=%t target=%s", proxy, target)
		originalCopy := append(socks.Addr(nil), original...)
		go router.receive(key, session, listener, peer, originalCopy)
	}
	payload := packet[3+len(original):]
	if session.proxy {
		payload = append(append([]byte(nil), session.header...), payload...)
	}
	_, err = session.connection.WriteTo(payload, session.remote)
	return err
}

func (router *udpRouter) receive(key string, session *udpRouteSession, listener *net.UDPConn, peer netip.AddrPort, original socks.Addr) {
	defer func() {
		router.Lock()
		delete(router.sessions, key)
		router.Unlock()
		session.connection.Close()
	}()
	buffer := make([]byte, udpBufSize)
	for {
		session.connection.SetReadDeadline(time.Now().Add(60 * time.Second))
		length, source, err := session.connection.ReadFrom(buffer)
		if err != nil {
			return
		}
		if source.String() != session.remote.String() {
			continue
		}
		payload := buffer[:length]
		if session.proxy {
			header := socks.SplitAddr(payload)
			if header == nil {
				continue
			}
			payload = payload[len(header):]
		}
		response := append([]byte{0, 0, 0}, original...)
		response = append(response, payload...)
		if _, err := listener.WriteToUDPAddrPort(response, peer); err != nil {
			return
		}
	}
}
