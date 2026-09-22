package main

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"strings"

	"golang.org/x/net/idna"
)

const maxRuleBytes = 4 * 1024 * 1024

type domainRules struct {
	proxy   map[string]bool
	direct  map[string]bool
	skipped int
}

func domainName(value string) string {
	value = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(value)), ".")
	ascii, err := idna.Lookup.ToASCII(value)
	if err != nil || len(ascii) > 253 || !strings.Contains(ascii, ".") || net.ParseIP(ascii) != nil {
		return ""
	}
	for _, label := range strings.Split(ascii, ".") {
		if len(label) == 0 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return ""
		}
		for _, letter := range label {
			if !(letter >= 'a' && letter <= 'z' || letter >= '0' && letter <= '9' || letter == '-') {
				return ""
			}
		}
	}
	return ascii
}

func parseDomainRules(content []byte) (*domainRules, error) {
	if len(content) == 0 || len(content) > maxRuleBytes {
		return nil, fmt.Errorf("invalid GFWList size")
	}
	text := strings.TrimSpace(string(content))
	if !strings.HasPrefix(text, "[AutoProxy") {
		decoded, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(text), ""))
		if err != nil {
			return nil, fmt.Errorf("GFWList must be Base64 or AutoProxy text")
		}
		text = strings.TrimSpace(string(decoded))
	}
	if !strings.HasPrefix(text, "[AutoProxy") {
		return nil, fmt.Errorf("missing AutoProxy header")
	}
	rules := &domainRules{proxy: make(map[string]bool), direct: make(map[string]bool)}
	scanner := bufio.NewScanner(strings.NewReader(text))
	scanner.Buffer(make([]byte, 4096), maxRuleBytes)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "!") || strings.HasPrefix(line, "[") {
			continue
		}
		exception := strings.HasPrefix(line, "@@")
		line = strings.TrimPrefix(line, "@@")
		if strings.HasPrefix(line, "/") || strings.ContainsAny(line, "$#") {
			rules.skipped++
			continue
		}
		line = strings.TrimLeft(line, "|.")
		line = strings.TrimPrefix(line, "*.")
		if strings.HasPrefix(line, "http://") || strings.HasPrefix(line, "https://") {
			parsed, err := url.Parse(line)
			if err != nil || (exception && parsed.EscapedPath() != "" && parsed.EscapedPath() != "/") {
				rules.skipped++
				continue
			}
			line = parsed.Hostname()
		} else {
			if boundary := strings.IndexAny(line, "/^|"); boundary >= 0 {
				if exception && line[boundary] == '/' && line[boundary:] != "/" {
					rules.skipped++
					continue
				}
				line = line[:boundary]
			}
		}
		domain := domainName(line)
		if domain == "" {
			rules.skipped++
			continue
		}
		if exception {
			rules.direct[domain] = true
		} else {
			rules.proxy[domain] = true
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(rules.proxy) == 0 {
		return nil, fmt.Errorf("GFWList contains no supported proxy domains")
	}
	return rules, nil
}

func hasDomain(domains map[string]bool, domain string) bool {
	for domain != "" {
		if domains[domain] {
			return true
		}
		boundary := strings.IndexByte(domain, '.')
		if boundary < 0 {
			break
		}
		domain = domain[boundary+1:]
	}
	return false
}

func (rules *domainRules) matches(host string) bool {
	domain := domainName(host)
	return domain != "" && !hasDomain(rules.direct, domain) && hasDomain(rules.proxy, domain)
}
