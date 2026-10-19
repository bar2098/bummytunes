#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-$(dirname "$(xcrun -f swiftc)")}"
SDK="${SDK:-$(xcrun --sdk macosx --show-sdk-path)}"; BUILD="$ROOT/build-mac"
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
  -module-name BummyShots -parse-as-library \
  -o "$BUILD/bummy-shots" "${SRCS[@]}" 2>&1 | grep -vE "^ld: warning" | grep -E "error:" | head -8 || true
"$BUILD/bummy-shots"
