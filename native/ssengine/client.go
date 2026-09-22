package main

import (
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/shadowsocks/go-shadowsocks2/core"
	"github.com/shadowsocks/go-shadowsocks2/socks"
)

var (
	ssMu      sync.Mutex
	ssStarted bool
)

func parseURL(s string) (addr, cipher, password string, err error) {
	u, err := url.Parse(s)
	if err != nil {
		return
	}
	addr = u.Host
	if u.User != nil {
		cipher = u.User.Username()
		password, _ = u.User.Password()
	}
	return
}

func startShadowsocksClient(ssURL, socksAddr, udpTunSpec, tcpTunSpec string, verbose bool) error {
	ssMu.Lock()
	defer ssMu.Unlock()
	if ssStarted {
		return nil
	}

	config.Verbose = verbose
	config.UDPTimeout = 5 * time.Minute

	addr, cipher, password, err := parseURL(ssURL)
	if err != nil {
		return fmt.Errorf("parse ss url: %w", err)
	}
	if addr == "" || cipher == "" {
		return fmt.Errorf("invalid ss url")
	}

	ciph, err := core.PickCipher(cipher, nil, password)
	if err != nil {
		return fmt.Errorf("cipher: %w", err)
	}

	if udpTunSpec != "" {
		for _, tun := range strings.Split(udpTunSpec, ",") {
			p := strings.SplitN(tun, "=", 2)
			if len(p) != 2 {
				continue
			}
			_, port, splitErr := net.SplitHostPort(p[1])
			if splitErr == nil && port == "53" && strings.Contains(","+tcpTunSpec+",", ","+tun+",") {
				go dnsUDPOverTCP(p[0])
			} else {
				go udpLocal(p[0], addr, p[1], ciph.PacketConn)
			}
		}
	}
	if tcpTunSpec != "" {
		for _, tun := range strings.Split(tcpTunSpec, ",") {
			p := strings.SplitN(tun, "=", 2)
			if len(p) != 2 {
				continue
			}
			go tcpTun(p[0], addr, p[1], ciph.StreamConn)
		}
	}
	if socksAddr != "" {
		socks.UDPEnabled = true
		go socksLocal(socksAddr, addr, ciph.StreamConn)
		go udpSocksLocal(socksAddr, addr, ciph.PacketConn)
	}

	ssStarted = true
	time.Sleep(150 * time.Millisecond)
	logf("ss client started socks=%s server=%s", socksAddr, addr)
	return nil
}
