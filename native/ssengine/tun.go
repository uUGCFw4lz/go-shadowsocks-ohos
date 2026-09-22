package main

import (
	"fmt"
	"log"
	"os"
	"sync"
	"syscall"

	"github.com/dosgo/go-tun2socks/tun2socks"
)

var (
	t2sMu      sync.Mutex
	t2sStarted bool
)

func startTun2Socks(tunFd int, socksAddr string, mtu int, dns string) error {
	t2sMu.Lock()
	if t2sStarted {
		t2sMu.Unlock()
		return nil
	}
	t2sStarted = true
	t2sMu.Unlock()

	if err := syscall.SetNonblock(tunFd, false); err != nil {
		log.Printf("SetNonblock(false) fd=%d: %v", tunFd, err)
	}
	dev := os.NewFile(uintptr(tunFd), "tun")
	if dev == nil {
		return fmt.Errorf("invalid tun fd %d", tunFd)
	}
	log.Printf("tun2socks start fd=%d socks=%s mtu=%d dns=%q", tunFd, socksAddr, mtu, dns)
	go func() {
		if err := tun2socks.StartFromIO(dev, mtu, socksAddr, dns); err != nil {
			log.Printf("tun2socks StartFromIO: %v", err)
		}
	}()
	return nil
}
