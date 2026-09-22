package main

import "time"

var config struct {
	Verbose    bool
	UDPTimeout time.Duration
	TCPCork    bool
}
