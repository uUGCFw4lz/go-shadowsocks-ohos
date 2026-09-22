package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"log"
	"os"
	"unsafe"
)

func writeErr(errBuf *C.char, errBufLen C.int, msg string) C.int {
	if errBuf == nil || errBufLen <= 0 {
		return 1
	}
	n := int(errBufLen) - 1
	if n > len(msg) {
		n = len(msg)
	}
	dst := unsafe.Slice((*byte)(unsafe.Pointer(errBuf)), int(errBufLen))
	copy(dst, msg[:n])
	dst[n] = 0
	return 1
}

//export SsSetLogPath
func SsSetLogPath(path *C.char) C.int {
	f, err := os.OpenFile(C.GoString(path), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return 1
	}
	log.SetOutput(f)
	logger.SetOutput(f)
	return 0
}

//export SsConfigureRouting
func SsConfigureRouting(path *C.char, errBuf *C.char, errBufLen C.int) C.int {
	if err := configureRouting(C.GoString(path)); err != nil {
		return writeErr(errBuf, errBufLen, err.Error())
	}
	return 0
}

//export SsStartClient
func SsStartClient(ssURL, socksAddr, udpTun, tcpTun *C.char, verbose C.int, errBuf *C.char, errBufLen C.int) C.int {
	err := startShadowsocksClient(
		C.GoString(ssURL),
		C.GoString(socksAddr),
		C.GoString(udpTun),
		C.GoString(tcpTun),
		verbose != 0,
	)
	if err != nil {
		return writeErr(errBuf, errBufLen, err.Error())
	}
	return 0
}

//export SsStartTun2Socks
func SsStartTun2Socks(tunFd C.int, socksAddr *C.char, mtu C.int, dns *C.char, errBuf *C.char, errBufLen C.int) C.int {
	err := startTun2Socks(int(tunFd), C.GoString(socksAddr), int(mtu), C.GoString(dns))
	if err != nil {
		return writeErr(errBuf, errBufLen, err.Error())
	}
	return 0
}

func main() {}
