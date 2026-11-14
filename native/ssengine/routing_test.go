package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/shadowsocks/go-shadowsocks2/socks"
	"golang.org/x/net/dns/dnsmessage"
)

func TestFakeIPPersistenceDoesNotBlockExistingRoutes(t *testing.T) {
	previous := routes
	defer func() { routes = previous }()
	rules, err := parseDomainRules([]byte("[AutoProxy 0.2.9]\n||blocked.test"))
	if err != nil {
		t.Fatal(err)
	}
	table := &routeTable{
		rules: rules, domains: map[string]string{"blocked.test": "198.18.0.1"},
		hosts: map[string]string{"198.18.0.1": "blocked.test"},
		path:  filepath.Join(t.TempDir(), "fake-ip.json"),
	}
	for index := 0; index < 20000; index++ {
		domain := fmt.Sprintf("%d.%s.blocked.test", index, strings.Repeat("a", 60))
		address := fmt.Sprintf("198.19.%d.%d", index/256, index%256)
		table.domains[domain] = address
		table.hosts[address] = domain
	}
	routes = table
	if err := syscall.Mkfifo(table.path+".tmp", 0600); err != nil {
		t.Fatal(err)
	}
	allocated := make(chan error, 1)
	go func() {
		_, err := table.fakeIP("new.blocked.test")
		allocated <- err
	}()
	reader, err := os.Open(table.path + ".tmp")
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	routed := make(chan error, 1)
	go func() {
		target, proxy, err := routeDestination("198.18.0.1:443")
		if err == nil && (target != "blocked.test:443" || !proxy) {
			err = fmt.Errorf("unexpected route: %s, proxy=%t", target, proxy)
		}
		if err == nil {
			address, lookupErr := table.fakeIP("blocked.test")
			err = lookupErr
			if err == nil && address.String() != "198.18.0.1" {
				err = fmt.Errorf("cached address changed: %s", address)
			}
		}
		routed <- err
	}()
	completed := false
	select {
	case err := <-routed:
		completed = true
		if err != nil {
			t.Error(err)
		}
	case <-time.After(time.Second):
		t.Error("existing route blocked by fake IP persistence")
	}
	io.Copy(io.Discard, reader)
	if err := <-allocated; err != nil {
		t.Error(err)
	}
	if !completed {
		<-routed
	}
}

func TestFakeIPFailedPersistenceDoesNotPublishMapping(t *testing.T) {
	table := &routeTable{domains: make(map[string]string), hosts: make(map[string]string),
		path: filepath.Join(t.TempDir(), "missing", "fake-ip.json")}
	if _, err := table.fakeIP("blocked.test"); err == nil {
		t.Fatal("expected persistence failure")
	}
	if len(table.domains) != 0 || len(table.hosts) != 0 {
		t.Fatal("failed write published a mapping")
	}
	if err := os.Mkdir(filepath.Dir(table.path), 0700); err != nil {
		t.Fatal(err)
	}
	address, err := table.fakeIP("blocked.test")
	if err != nil || address.String() != "198.18.0.1" {
		t.Fatalf("retry failed: %s, %v", address, err)
	}
}

func TestRoutingConfigurationAndPersistence(t *testing.T) {
	previous := routes
	defer func() { routes = previous }()
	dir := t.TempDir()
	configPath := filepath.Join(dir, "routing.json")
	listPath := filepath.Join(dir, "gfwlist.json")
	writeJSON := func(path string, value interface{}) {
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeJSON(configPath, routingOptions{Mode: "gfwlist", ListPath: listPath})
	routes = &routeTable{domains: make(map[string]string), hosts: make(map[string]string)}
	if err := configureRouting(configPath); err == nil {
		t.Fatal("missing list accepted")
	}
	writeJSON(listPath, map[string]string{"content": "[AutoProxy 0.2.9]\n||blocked.test\n"})
	if err := configureRouting(configPath); err != nil {
		t.Fatal(err)
	}
	address, err := routes.fakeIP("blocked.test")
	if err != nil {
		t.Fatal(err)
	}
	routes = &routeTable{domains: make(map[string]string), hosts: make(map[string]string)}
	if err := configureRouting(configPath); err != nil {
		t.Fatal(err)
	}
	if target, proxy, err := routeDestination(address.String() + ":443"); err != nil || !proxy || target != "blocked.test:443" {
		t.Fatal("persisted mapping lost")
	}
	writeJSON(listPath, map[string]string{"content": "not a list"})
	if target, proxy, err := routeDestination(address.String() + ":443"); err != nil || !proxy || target != "blocked.test:443" {
		t.Fatal("routing re-read the list instead of using memory")
	}
	if err := configureRouting(configPath); err == nil {
		t.Fatal("invalid list accepted")
	}
	if !routingEnabled() {
		t.Fatal("invalid list disabled current route")
	}
	writeJSON(configPath, routingOptions{Mode: "global", ListPath: listPath})
	if err := configureRouting(configPath); err != nil {
		t.Fatal("global should not require valid list:", err)
	}
	if routingEnabled() {
		t.Fatal("global mode not restored")
	}
	if target, proxy, err := routeDestination("192.0.2.1:443"); err != nil || !proxy || target != "192.0.2.1:443" {
		t.Fatal("global IP routing changed")
	}
}

func TestDirectDNSExchange(t *testing.T) {
	for _, invalid := range []bool{false, true} {
		listener, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		listener.SetReadDeadline(time.Now().Add(3 * time.Second))
		finished := make(chan error, 1)
		go func() {
			buffer := make([]byte, 1024)
			length, source, err := listener.ReadFromUDP(buffer)
			if err != nil {
				finished <- err
				return
			}
			var response dnsmessage.Message
			if err := response.Unpack(buffer[:length]); err != nil {
				finished <- err
				return
			}
			response.Response = true
			if invalid {
				response.ID++
			}
			packet, err := response.Pack()
			if err == nil {
				_, err = listener.WriteToUDP(packet, source)
			}
			finished <- err
		}()
		query := dnsmessage.Message{Header: dnsmessage.Header{ID: 42}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("direct.test."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
		packet, _ := query.Pack()
		_, err = exchangeDirectDNS(listener.LocalAddr().String(), packet)
		if invalid != (err != nil) {
			t.Fatalf("invalid=%v err=%v", invalid, err)
		}
		if err := <-finished; err != nil {
			t.Fatal(err)
		}
	}
}

func TestTCPDirectAndProxy(t *testing.T) {
	previous := routes
	rules, _ := parseDomainRules([]byte("[AutoProxy 0.2.9]\n||blocked.test"))
	routes = &routeTable{rules: rules, domains: make(map[string]string), hosts: make(map[string]string)}
	defer func() { routes = previous }()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	counters := &trafficCounters{}
	identity := func(connection net.Conn) net.Conn { return &meteredConn{Conn: connection, counters: counters} }
	connection, err := dialTCPDestination(socks.ParseAddr(listener.Addr().String()), "127.0.0.1:1", identity, true)
	if err != nil {
		t.Fatal("direct tried SS:", err)
	}
	if _, err := connection.Write([]byte("direct traffic")); err != nil {
		t.Fatal(err)
	}
	if counters.uploaded.Load() != 0 {
		t.Fatal("direct TCP traffic counted as proxy traffic")
	}
	connection.Close()
	accepted, _ := listener.Accept()
	accepted.Close()
	fake, _ := routes.fakeIP("blocked.test")
	connection, err = dialTCPDestination(socks.ParseAddr(fake.String()+":443"), listener.Addr().String(), identity, true)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	accepted, err = listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer accepted.Close()
	accepted.SetReadDeadline(time.Now().Add(time.Second))
	header, err := socks.ReadAddr(accepted)
	if err != nil || header.String() != "blocked.test:443" {
		t.Fatalf("proxy header %v: %v", header, err)
	}
	if counters.uploaded.Load() != uint64(len(header)) {
		t.Fatal("proxy TCP upload not counted")
	}
	if _, err := accepted.Write([]byte("reply")); err != nil {
		t.Fatal(err)
	}
	connection.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := io.ReadFull(connection, make([]byte, 5)); err != nil {
		t.Fatal(err)
	}
	if counters.downloaded.Load() != 5 {
		t.Fatal("proxy TCP download not counted")
	}
}

func TestUnknownPublicIPTimeoutFallsBackToProxy(t *testing.T) {
	previousRoutes, previousDial := routes, dialRouteTCP
	defer func() { routes, dialRouteTCP = previousRoutes, previousDial }()
	rules, err := parseDomainRules([]byte("[AutoProxy 0.2.9]\n||google.com"))
	if err != nil {
		t.Fatal(err)
	}
	routes = &routeTable{rules: rules, domains: make(map[string]string), hosts: make(map[string]string)}
	for _, testCase := range []struct {
		target   string
		err      error
		fallback bool
	}{
		{"142.251.154.119:443", nil, false},
		{"142.251.154.119:443", os.ErrDeadlineExceeded, true},
		{"192.168.1.1:443", os.ErrDeadlineExceeded, false},
		{"127.0.0.1:443", os.ErrDeadlineExceeded, false},
		{"direct.test:443", os.ErrDeadlineExceeded, false},
		{"142.251.154.119:443", syscall.ECONNREFUSED, false},
	} {
		t.Run(fmt.Sprintf("%s/%v", testCase.target, testCase.err), func(t *testing.T) {
			calls := 0
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()
			server.SetReadDeadline(time.Now().Add(time.Second))
			headerRead := make(chan error, 1)
			if testCase.fallback {
				go func() {
					header, err := socks.ReadAddr(server)
					if err == nil && header.String() != testCase.target {
						err = fmt.Errorf("fallback changed destination: %s", header)
					}
					headerRead <- err
				}()
			}
			dialRouteTCP = func(network, address string, timeout time.Duration) (net.Conn, error) {
				calls++
				if calls == 1 {
					if address != testCase.target || (testCase.fallback && timeout != 1500*time.Millisecond) {
						t.Errorf("unexpected direct dial %s %s", address, timeout)
					}
					if testCase.err == nil {
						return client, nil
					}
					return nil, testCase.err
				}
				if address != "proxy.test:8388" {
					t.Errorf("unexpected proxy %s", address)
				}
				return client, nil
			}
			connection, err := dialTCPDestination(socks.ParseAddr(testCase.target), "proxy.test:8388", func(connection net.Conn) net.Conn { return connection }, true)
			if testCase.fallback {
				if err != nil || calls != 2 || connection == nil {
					t.Fatalf("fallback failed: calls=%d error=%v", calls, err)
				}
				if err := <-headerRead; err != nil {
					t.Fatal(err)
				}
			} else if calls != 1 || err != testCase.err {
				t.Fatalf("direct-only route changed: calls=%d error=%v", calls, err)
			}
			if testCase.err == nil && connection != client {
				t.Fatal("successful direct connection was replaced")
			}
		})
	}
}

func TestUDPSplitAndFakeReply(t *testing.T) {
	previous := routes
	rules, _ := parseDomainRules([]byte("[AutoProxy 0.2.9]\n||blocked.test"))
	routes = &routeTable{rules: rules, domains: make(map[string]string), hosts: make(map[string]string)}
	defer func() { routes = previous }()
	fake, _ := routes.fakeIP("blocked.test")
	listen := func() *net.UDPConn {
		connection, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { connection.Close() })
		connection.SetReadDeadline(time.Now().Add(3 * time.Second))
		return connection
	}
	direct, proxyServer, local, client := listen(), listen(), listen(), listen()
	counters := &trafficCounters{}
	shadow := func(connection net.PacketConn) net.PacketConn {
		return &meteredPacketConn{PacketConn: connection, counters: counters}
	}
	router := &udpRouter{sessions: make(map[string]*udpRouteSession)}
	defer func() {
		router.Lock()
		defer router.Unlock()
		for _, session := range router.sessions {
			session.connection.Close()
		}
	}()
	for _, proxy := range []bool{false, true} {
		target := direct.LocalAddr().String()
		upstream := direct
		if proxy {
			target, upstream = fake.String()+":443", proxyServer
		}
		packet := append([]byte{0, 0, 0}, socks.ParseAddr(target)...)
		packet = append(packet, []byte("hello")...)
		if err := router.send(local, client.LocalAddr().(*net.UDPAddr).AddrPort(), packet, proxyServer.LocalAddr(), shadow); err != nil {
			t.Fatal(err)
		}
		buffer := make([]byte, 1024)
		length, source, err := upstream.ReadFromUDP(buffer)
		if err != nil {
			t.Fatal(err)
		}
		payload := buffer[:length]
		expected := uint64(0)
		if proxy {
			expected = uint64(length)
		}
		if proxy {
			header := socks.SplitAddr(payload)
			if header == nil || header.String() != "blocked.test:443" {
				t.Fatal("missing restored domain")
			}
			payload = payload[len(header):]
		}
		if !bytes.Equal(payload, []byte("hello")) {
			t.Fatal("bad payload")
		}
		upstream.WriteToUDP(buffer[:length], source)
		length, _, err = client.ReadFromUDP(buffer)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(buffer[:length], packet) {
			t.Fatal("SOCKS reply must restore original destination")
		}
		if up, down := counters.uploaded.Load(), counters.downloaded.Load(); up != expected || down != expected {
			t.Fatalf("UDP proxy=%t: up=%d down=%d want=%d", proxy, up, down, expected)
		}
	}
}

func TestFakeDNSAndRouting(t *testing.T) {
	rules, err := parseDomainRules([]byte("[AutoProxy 0.2.9]\n||blocked.test\n@@||safe.blocked.test\n"))
	if err != nil {
		t.Fatal(err)
	}
	previous := routes
	routes = &routeTable{rules: rules, domains: make(map[string]string), hosts: make(map[string]string), path: filepath.Join(t.TempDir(), "fake-ip.json")}
	defer func() { routes = previous }()
	name := dnsmessage.MustNewName("www.blocked.test.")
	query := dnsmessage.Message{Header: dnsmessage.Header{ID: 42, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	data, _ := query.Pack()
	answer, err := routingDNS("unused", data)
	if err != nil {
		t.Fatal(err)
	}
	var response dnsmessage.Message
	if err := response.Unpack(answer); err != nil {
		t.Fatal(err)
	}
	if response.ID != 42 || len(response.Answers) != 1 {
		t.Fatal("invalid fake DNS reply")
	}
	address, err := routes.fakeIP("www.blocked.test")
	if err != nil {
		t.Fatal(err)
	}
	target, proxy, err := routeDestination(address.String() + ":443")
	if err != nil || !proxy || target != "www.blocked.test:443" {
		t.Fatalf("%s %v %v", target, proxy, err)
	}
	for _, direct := range []string{"safe.blocked.test:443", "direct.test:443", "192.0.2.1:443"} {
		if _, proxy, err := routeDestination(direct); err != nil || proxy {
			t.Fatalf("unexpected proxy for %s", direct)
		}
	}
	if _, _, err := routeDestination("198.19.255.254:443"); err == nil {
		t.Fatal("unknown fake IP accepted")
	}
	if _, err := os.Stat(routes.path); err != nil {
		t.Fatal(err)
	}
	query.Questions[0].Type = dnsmessage.TypeAAAA
	data, _ = query.Pack()
	answer, err = routingDNS("unused", data)
	if err != nil {
		t.Fatal(err)
	}
	response.Unpack(answer)
	if len(response.Answers) != 0 {
		t.Fatal("fake IPv6 must not escape IPv4 VPN")
	}
	routes.rules = nil
	if target, proxy, err := routeDestination(address.String() + ":443"); err != nil || !proxy || target != "www.blocked.test:443" {
		t.Fatal("global mode lost cached fake IP")
	}
}

func TestSOCKSDNSMultipleQueriesOnSameSocket(t *testing.T) {
	previous := routes
	rules, err := parseDomainRules([]byte("[AutoProxy 0.2.9]\n||google.com"))
	if err != nil {
		t.Fatal(err)
	}
	routes = &routeTable{rules: rules, domains: make(map[string]string), hosts: make(map[string]string)}
	defer func() { routes = previous }()
	listener, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		serveUDPSocksLocal(listener, nil, func(connection net.PacketConn) net.PacketConn { return connection })
	}()
	defer func() {
		listener.Close()
		<-finished
	}()
	client, err := net.DialUDP("udp", nil, listener.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.SetDeadline(time.Now().Add(3 * time.Second))
	header := append([]byte{0, 0, 0}, socks.ParseAddr("8.8.8.8:53")...)
	types := []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA, dnsmessage.Type(65)}
	for round := 0; round < 2; round++ {
		for index, queryType := range types {
			query := dnsmessage.Message{
				Header:    dnsmessage.Header{ID: uint16(round*len(types) + index + 1)},
				Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("www.google.com."), Type: queryType, Class: dnsmessage.ClassINET}},
			}
			packet, err := query.Pack()
			if err != nil {
				t.Fatal(err)
			}
			if _, err := client.Write(append(append([]byte(nil), header...), packet...)); err != nil {
				t.Fatal(err)
			}
		}
		seen := make(map[uint16]bool)
		for range types {
			buffer := make([]byte, 4096)
			length, err := client.Read(buffer)
			if err != nil {
				t.Fatal("DNS query lost on reused UDP socket:", err)
			}
			if length < len(header) || !bytes.Equal(buffer[:len(header)], header) {
				t.Fatal("DNS response lost original SOCKS address")
			}
			var response dnsmessage.Message
			if err := response.Unpack(buffer[len(header):length]); err != nil {
				t.Fatal(err)
			}
			index := int(response.ID) - round*len(types) - 1
			if index < 0 || index >= len(types) || seen[response.ID] || !response.Response || len(response.Questions) != 1 {
				t.Fatal("invalid DNS transaction")
			}
			seen[response.ID] = true
			if response.Questions[0].Type != types[index] || (types[index] == dnsmessage.TypeA) != (len(response.Answers) == 1) {
				t.Fatal("invalid split DNS answer")
			}
		}
	}
}
