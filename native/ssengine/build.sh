#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/../.." && pwd)"
NDK="${OHOS_NDK:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"
CC="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
SYSROOT="$NDK/sysroot"
GO="${OHOS_GO:-go}"
HOST_GO="${HOST_GO:-go}"
export GOTOOLCHAIN=local
export GOWORK=off
if ! command -v "$GO" > /dev/null || [[ ! -x "$CC" ]]; then
  printf '%s\n' 'Set OHOS_GO to an OpenHarmony-enabled Go executable and OHOS_NDK to the native SDK directory.' >&2
  exit 1
fi
if ! "$GO" tool dist list | grep -x 'openharmony/arm64' > /dev/null; then
  printf '%s\n' 'Set OHOS_GO to an OpenHarmony-enabled Go executable; standard Linux Go TLS cannot be loaded on OHOS.' >&2
  exit 1
fi

cd "$ROOT"
GOOS="$("$HOST_GO" env GOHOSTOS)" GOARCH="$("$HOST_GO" env GOHOSTARCH)" CGO_ENABLED=0 \
  "$HOST_GO" test -mod=readonly client.go tcp.go udp.go config.go log.go rules.go routing.go routing_udp.go \
    client_test.go udp_test.go rules_test.go routing_test.go

export CGO_ENABLED=1
export GOOS=openharmony
export GOARCH=arm64
export CC
export AR="$NDK/llvm/bin/llvm-ar"
export CGO_CFLAGS="--sysroot=${SYSROOT} -D__MUSL__ -fPIC"
export CGO_LDFLAGS="--sysroot=${SYSROOT} -fPIC"

LIBS="$PROJECT_ROOT/entry/libs/arm64-v8a"
mkdir -p "$LIBS"
"$GO" build -mod=readonly -buildmode=c-shared -ldflags '-s -w -extldflags "-Wl,-soname,libssgo.so -Wl,-z,max-page-size=16384"' \
  -o "$LIBS/libssgo.so" .
# Do NOT write libssengine.so here. That name is the Harmony NAPI wrapper
# produced by CMake; a Go binary with the same name would overwrite it in HAP.
rm -f "$LIBS/libssengine.so"

"$NDK/llvm/bin/llvm-nm" -D "$LIBS/libssgo.so" | grep -E 'SsStart|SsSet'
file "$LIBS/libssgo.so"
ls -lh "$LIBS/libssgo.so"
