package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func TestExchangeDNSTCP(t *testing.T) {
	for _, invalid := range []bool{false, true} {
		name := "fragmented response"
		if invalid {
			name = "mismatched transaction"
		}
		t.Run(name, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			query := []byte{0x12, 0x34, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0}
			response := append([]byte(nil), query...)
			response[2] = 0x81
			if invalid {
				response[0]++
			}
			finished := make(chan error, 1)
			go func() {
				connection, err := listener.Accept()
				if err != nil {
					finished <- err
					return
				}
				defer connection.Close()
				connection.SetDeadline(time.Now().Add(3 * time.Second))
				frame := make([]byte, len(query)+2)
				_, err = io.ReadFull(connection, frame)
				if err == nil && (int(binary.BigEndian.Uint16(frame)) != len(query) || !bytes.Equal(frame[2:], query)) {
					err = io.ErrUnexpectedEOF
				}
				if err == nil {
					frame[0], frame[1] = 0, byte(len(response))
					copy(frame[2:], response)
					for _, value := range frame {
						if _, err = connection.Write([]byte{value}); err != nil {
							break
						}
					}
				}
				finished <- err
			}()
			actual, err := exchangeDNSTCP(listener.Addr().String(), query)
			if invalid && err == nil {
				t.Error("expected invalid DNS response error")
			}
			if !invalid && (err != nil || !bytes.Equal(actual, response)) {
				t.Errorf("response %x, error %v", actual, err)
			}
			if err := <-finished; err != nil {
				t.Fatal(err)
			}
		})
	}
}
