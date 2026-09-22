package main

import (
	"encoding/base64"
	"os"
	"testing"
)

func TestDomainRules(t *testing.T) {
	text := "[AutoProxy 0.2.9]\n! comment\n||example.com\n@@||safe.example.com\n.google.com\n|https://blocked.test/path\n@@|https://blocked.test/allowed\n/bad.*/\n*.other.test\n"
	for _, content := range []string{text, base64.StdEncoding.EncodeToString([]byte(text))} {
		rules, err := parseDomainRules([]byte(content))
		if err != nil {
			t.Fatal(err)
		}
		for host, want := range map[string]bool{
			"example.com": true, "www.example.com": true, "WWW.EXAMPLE.COM.": true,
			"notexample.com": false, "example.com.evil.test": false,
			"safe.example.com": false, "sub.safe.example.com": false,
			"google.com": true, "blocked.test": true, "sub.other.test": true,
			"192.0.2.1": false, "direct.test": false,
		} {
			if got := rules.matches(host); got != want {
				t.Errorf("matches(%q)=%v, want %v", host, got, want)
			}
		}
		if rules.skipped != 2 {
			t.Errorf("skipped=%d", rules.skipped)
		}
	}
}

func TestRejectInvalidRules(t *testing.T) {
	for _, content := range []string{"", "<html>error</html>", "[AutoProxy 0.2.9]\n! empty", base64.StdEncoding.EncodeToString([]byte("garbage"))} {
		if _, err := parseDomainRules([]byte(content)); err == nil {
			t.Errorf("accepted invalid list %q", content)
		}
	}
}

func TestExternalGFWList(t *testing.T) {
	path := os.Getenv("GFWLIST_TEST_FILE")
	if path == "" {
		t.Skip("GFWLIST_TEST_FILE is not set")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	rules, err := parseDomainRules(content)
	if err != nil {
		t.Fatal(err)
	}
	if !rules.matches("www.google.com") || !rules.matches("www.youtube.com") || rules.matches("www.baidu.com") || rules.matches("fonts.googleapis.com") {
		t.Fatal("real-list routing mismatch")
	}
	t.Logf("proxy=%d exceptions=%d skipped=%d", len(rules.proxy), len(rules.direct), rules.skipped)
}
