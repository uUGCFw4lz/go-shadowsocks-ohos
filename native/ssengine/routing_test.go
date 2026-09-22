package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/shadowsocks/go-shadowsocks2/socks"
	"golang.org/x/net/dns/dnsmessage"
)

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
	identity := func(connection net.Conn) net.Conn { return connection }
	connection, err := dialTCPDestination(socks.ParseAddr(listener.Addr().String()), "127.0.0.1:1", identity, true)
	if err != nil {
		t.Fatal("direct tried SS:", err)
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
		if err := router.send(local, client.LocalAddr().(*net.UDPAddr).AddrPort(), packet, proxyServer.LocalAddr(), func(connection net.PacketConn) net.PacketConn { return connection }); err != nil {
			t.Fatal(err)
		}
		buffer := make([]byte, 1024)
		length, source, err := upstream.ReadFromUDP(buffer)
		if err != nil {
			t.Fatal(err)
		}
		payload := buffer[:length]
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
