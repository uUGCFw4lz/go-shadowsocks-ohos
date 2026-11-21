package main

import (
	"bufio"
	"embed"
	"fmt"
	"net/netip"
	"regexp"
	"strings"
)

//go:embed acl/*.acl
var bundledACL embed.FS

type aclList struct {
	networks map[netip.Prefix]bool
	domains  map[string]bool
	patterns []*regexp.Regexp
}

type aclRules struct {
	defaultProxy bool
	direct       aclList
	proxy        aclList
}

func validRouteMode(mode string) bool {
	switch mode {
	case "global", "gfwlist", "bypass-lan", "bypass-china", "bypass-lan-china", "china-list":
		return true
	}
	return false
}

func parseACL(content string) (*aclRules, error) {
	newList := func() aclList {
		return aclList{networks: make(map[netip.Prefix]bool), domains: make(map[string]bool)}
	}
	rules := &aclRules{direct: newList(), proxy: newList()}
	var list *aclList
	header := false
	scanner := bufio.NewScanner(strings.NewReader(content))
	scanner.Buffer(make([]byte, 4096), maxRuleBytes)
	for scanner.Scan() {
		line := strings.TrimSpace(strings.SplitN(scanner.Text(), "#", 2)[0])
		switch line {
		case "":
			continue
		case "[proxy_all]":
			rules.defaultProxy, header = true, true
			continue
		case "[bypass_all]":
			rules.defaultProxy, header = false, true
			continue
		case "[bypass_list]":
			list = &rules.direct
			continue
		case "[proxy_list]":
			list = &rules.proxy
			continue
		}
		if list == nil || strings.HasPrefix(line, "[") {
			return nil, fmt.Errorf("unsupported ACL section or rule: %s", line)
		}
		if prefix, err := netip.ParsePrefix(line); err == nil {
			list.networks[prefix.Masked()] = true
			continue
		}
		if address, err := netip.ParseAddr(line); err == nil {
			list.networks[netip.PrefixFrom(address, address.BitLen())] = true
			continue
		}
		// Android's common suffix expression can use the existing hash matcher.
		if strings.HasPrefix(line, `(?:^|\.)`) && strings.HasSuffix(line, "$") {
			domain := domainName(strings.ReplaceAll(strings.TrimSuffix(strings.TrimPrefix(line, `(?:^|\.)`), "$"), `\.`, "."))
			if domain != "" {
				list.domains[domain] = true
				continue
			}
		}
		pattern, err := regexp.Compile(line)
		if err != nil {
			return nil, fmt.Errorf("invalid ACL expression %q: %w", line, err)
		}
		list.patterns = append(list.patterns, pattern)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if !header || len(rules.direct.networks)+len(rules.proxy.networks)+len(rules.direct.domains)+len(rules.proxy.domains)+len(rules.direct.patterns)+len(rules.proxy.patterns) == 0 {
		return nil, fmt.Errorf("empty ACL or missing default policy")
	}
	return rules, nil
}

func (list *aclList) matchesDomain(host string) bool {
	if hasDomain(list.domains, host) {
		return true
	}
	for _, pattern := range list.patterns {
		if pattern.MatchString(host) {
			return true
		}
	}
	return false
}

func (list *aclList) matchesIP(address netip.Addr) bool {
	address = address.Unmap()
	for bits := address.BitLen(); bits >= 0; bits-- {
		if list.networks[netip.PrefixFrom(address, bits).Masked()] {
			return true
		}
	}
	return false
}

func (rules *aclRules) domainPolicy(host string) (proxy, explicit bool) {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if rules.direct.matchesDomain(host) {
		return false, true
	}
	if rules.proxy.matchesDomain(host) {
		return true, true
	}
	return rules.defaultProxy, false
}

func (rules *aclRules) proxyIP(address netip.Addr) bool {
	if rules.direct.matchesIP(address) {
		return false
	}
	if rules.proxy.matchesIP(address) {
		return true
	}
	return rules.defaultProxy
}
