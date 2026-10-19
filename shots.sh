#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TC="$HOME/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr/bin"
SDK="$ROOT/toolchain/MacOSX15.5.sdk"; BUILD="$ROOT/build-mac"
SRCS=(); for f in "$ROOT"/app/Sources/BummyTunesApp/*.swift; do
  case "$f" in *BummyTunesApp.swift) ;; *) SRCS+=("$f");; esac
done
SRCS+=("$ROOT/app/Sources/BummyShots/main.swift")
mkdir -p /tmp/shots
"$TC/swiftc" -target arm64-apple-macos14.0 -sdk "$SDK" -O \
  -Xcc -DACCELERATE_NEW_LAPACK=1 \
  -I "$ROOT/app/Sources/COnnxRuntime/include" -Xcc -I"$ROOT/app/Sources/COnnxRuntime/include" \
  -I "$BUILD" -L "$BUILD" -lBummyTunesCore \
  -L /opt/homebrew/opt/onnxruntime/lib -lonnxruntime \
  -Xlinker -rpath -Xlinker /opt/homebrew/opt/onnxruntime/lib \
  -use-ld=/opt/homebrew/opt/lld/bin/ld64.lld \
  -module-name BummyShots -parse-as-library \
  -o "$BUILD/bummy-shots" "${SRCS[@]}" 2>&1 | grep -vE "^ld64.lld: warning" | grep -E "error:" | head -8
"$BUILD/bummy-shots"
