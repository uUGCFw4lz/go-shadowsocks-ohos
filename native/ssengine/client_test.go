package main

import (
	"bytes"
	"io"
	"net"
	"testing"
	"time"

	"github.com/shadowsocks/go-shadowsocks2/core"
)

func TestXChaChaClient(t *testing.T) {
	t.Setenv("SHADOWSOCKS_SF_CAPACITY", "-1")
	for _, method := range []string{"xchacha20-ietf-poly1305", "AEAD_XCHACHA20_POLY1305"} {
		t.Run(method, func(t *testing.T) {
			address, cipherName, password, err := parseURL("ss://" + method + ":test%40password@127.0.0.1:8388")
			if err != nil || address != "127.0.0.1:8388" || password != "test@password" {
				t.Fatalf("parseURL: address=%q, error=%v", address, err)
			}
			clientCipher, err := core.PickCipher(cipherName, nil, password)
			if err != nil {
				t.Fatalf("client cipher: %v", err)
			}
			counters := &trafficCounters{}
			clientCipher = meteredCipher{Cipher: clientCipher, counters: counters}
			serverCipher, err := core.PickCipher("AEAD_XCHACHA20_POLY1305", nil, password)
			if err != nil {
				t.Fatalf("server cipher: %v", err)
			}
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()
			client.SetDeadline(time.Now().Add(3 * time.Second))
			server.SetDeadline(time.Now().Add(3 * time.Second))
			payload := []byte("xchacha client round trip")
			finished := make(chan error, 1)
			go func() {
				_, writeErr := clientCipher.StreamConn(client).Write(payload)
				finished <- writeErr
			}()
			actual := make([]byte, len(payload))
			if _, err := io.ReadFull(serverCipher.StreamConn(server), actual); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(actual, payload) {
				t.Fatalf("unexpected plaintext: %q", actual)
			}
			if err := <-finished; err != nil {
				t.Fatal(err)
			}
			if up, down := counters.uploaded.Load(), counters.downloaded.Load(); up <= uint64(len(payload)) || down != 0 {
				t.Fatalf("expected encrypted upload including overhead: up=%d down=%d", up, down)
			}
		})
	}
}
