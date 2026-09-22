package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

type routingOptions struct {
	Mode     string `json:"mode"`
	ListPath string `json:"listPath"`
}

type routeTable struct {
	sync.RWMutex
	rules   *domainRules
	domains map[string]string
	hosts   map[string]string
	path    string
}

var routes = &routeTable{domains: make(map[string]string), hosts: make(map[string]string)}
var fakeNetwork = netip.MustParsePrefix("198.18.0.0/15")

func configureRouting(path string) error {
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var options routingOptions
	if err := json.Unmarshal(content, &options); err != nil {
		return err
	}
	if options.Mode != "global" && options.Mode != "gfwlist" {
		return fmt.Errorf("invalid route mode")
	}
	var rules *domainRules
	if options.Mode == "gfwlist" {
		file, err := os.Open(options.ListPath)
		if err != nil {
			return err
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, maxRuleBytes+1))
		if err != nil {
			return err
		}
		if len(data) > maxRuleBytes {
			return fmt.Errorf("GFWList snapshot too large")
		}
		var snapshot struct {
			Content string `json:"content"`
		}
		if err := json.Unmarshal(data, &snapshot); err != nil {
			return fmt.Errorf("invalid GFWList snapshot: %w", err)
		}
		rules, err = parseDomainRules([]byte(snapshot.Content))
		if err != nil {
			return err
		}
	}
	routes.Lock()
	defer routes.Unlock()
	mapPath := filepath.Join(filepath.Dir(path), "fake-ip.json")
	if routes.path != mapPath {
		domains := make(map[string]string)
		data, readErr := os.ReadFile(mapPath)
		if readErr == nil {
			if err := json.Unmarshal(data, &domains); err != nil {
				return fmt.Errorf("invalid fake IP cache: %w", err)
			}
		} else if !os.IsNotExist(readErr) {
			return readErr
		}
		hosts := make(map[string]string)
		for domain, address := range domains {
			ip, err := netip.ParseAddr(address)
			if err != nil || !fakeNetwork.Contains(ip) || domainName(domain) != domain || hosts[address] != "" {
				return fmt.Errorf("invalid fake IP entry")
			}
			hosts[address] = domain
		}
		routes.domains, routes.hosts, routes.path = domains, hosts, mapPath
	}
	routes.rules = rules
	if rules != nil {
		logf("route=gfwlist proxy=%d exceptions=%d skipped=%d", len(rules.proxy), len(rules.direct), rules.skipped)
	} else {
		logf("route=global")
	}
	return nil
}

func routingEnabled() bool {
	routes.RLock()
	defer routes.RUnlock()
	return routes.rules != nil
}

func (table *routeTable) fakeIP(domain string) (netip.Addr, error) {
	table.Lock()
	defer table.Unlock()
	if address := table.domains[domain]; address != "" {
		return netip.ParseAddr(address)
	}
	for offset := 1; offset < 131071; offset++ {
		address := netip.AddrFrom4([4]byte{198, byte(18 + (offset >> 16)), byte(offset >> 8), byte(offset)})
		if table.hosts[address.String()] != "" {
			continue
		}
		table.domains[domain] = address.String()
		if table.path != "" {
			data, err := json.Marshal(table.domains)
			if err == nil {
				err = os.WriteFile(table.path+".tmp", data, 0600)
			}
			if err == nil {
				err = os.Rename(table.path+".tmp", table.path)
			}
			if err != nil {
				delete(table.domains, domain)
				return netip.Addr{}, err
			}
		}
		table.hosts[address.String()] = domain
		return address, nil
	}
	return netip.Addr{}, fmt.Errorf("fake IP pool exhausted")
}

func routeDestination(target string) (string, bool, error) {
	host, port, err := net.SplitHostPort(target)
	if err != nil {
		return "", false, err
	}
	routes.RLock()
	defer routes.RUnlock()
	if ip, err := netip.ParseAddr(host); err == nil && fakeNetwork.Contains(ip) {
		domain := routes.hosts[ip.String()]
		if domain == "" {
			return "", false, fmt.Errorf("unknown fake IP %s", host)
		}
		host = domain
	}
	proxy := routes.rules == nil || routes.rules.matches(host)
	return net.JoinHostPort(host, port), proxy, nil
}

func routingDNS(tunnel string, query []byte) ([]byte, error) {
	if !routingEnabled() {
		return exchangeDNSTCP(tunnel, query)
	}
	var request dnsmessage.Message
	if err := request.Unpack(query); err != nil {
		return nil, err
	}
	if request.Response || request.OpCode != 0 || len(request.Questions) != 1 {
		return nil, fmt.Errorf("unsupported DNS question")
	}
	question := request.Questions[0]
	host := domainName(question.Name.String())
	routes.RLock()
	matched := routes.rules != nil && routes.rules.matches(host)
	routes.RUnlock()
	if !matched {
		return directDNS(query)
	}
	if question.Class != dnsmessage.ClassINET {
		return nil, fmt.Errorf("unsupported DNS class")
	}
	response := dnsmessage.Message{Header: dnsmessage.Header{ID: request.ID, Response: true, RecursionDesired: request.RecursionDesired, RecursionAvailable: true}, Questions: request.Questions}
	switch question.Type {
	case dnsmessage.TypeA:
		address, err := routes.fakeIP(host)
		if err != nil {
			return nil, err
		}
		response.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: address.As4()}}}
	case dnsmessage.TypeAAAA, dnsmessage.Type(64), dnsmessage.Type(65):
	default:
		return exchangeDNSTCP(tunnel, query)
	}
	return response.Pack()
}

func directDNS(query []byte) ([]byte, error) {
	var lastErr error
	for _, address := range []string{"223.5.5.5:53", "119.29.29.29:53"} {
		response, err := exchangeDirectDNS(address, query)
		if err == nil {
			return response, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

func exchangeDirectDNS(address string, query []byte) ([]byte, error) {
	connection, err := net.DialTimeout("udp", address, 3*time.Second)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := connection.Write(query); err != nil {
		return nil, err
	}
	buffer := make([]byte, 65535)
	length, err := connection.Read(buffer)
	if err != nil {
		return nil, err
	}
	var request, response dnsmessage.Message
	if err := request.Unpack(query); err != nil {
		return nil, err
	}
	if err := response.Unpack(buffer[:length]); err != nil {
		return nil, err
	}
	if response.ID != request.ID || !response.Response || len(request.Questions) != 1 || len(response.Questions) != 1 || response.Questions[0] != request.Questions[0] {
		return nil, fmt.Errorf("mismatched direct DNS response")
	}
	if response.Truncated {
		return exchangeDNSTCP(address, query)
	}
	return buffer[:length], nil
}

func serveRoutingDNS(connection net.Conn) {
	for {
		connection.SetDeadline(time.Now().Add(10 * time.Second))
		var prefix [2]byte
		if _, err := io.ReadFull(connection, prefix[:]); err != nil {
			return
		}
		query := make([]byte, binary.BigEndian.Uint16(prefix[:]))
		if _, err := io.ReadFull(connection, query); err != nil {
			return
		}
		response, err := routingDNS("127.0.0.1:8053", query)
		if err != nil {
			return
		}
		binary.BigEndian.PutUint16(prefix[:], uint16(len(response)))
		if _, err := io.Copy(connection, strings.NewReader(string(prefix[:])+string(response))); err != nil {
			return
		}
	}
}
