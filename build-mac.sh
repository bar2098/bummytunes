#!/bin/bash
# Build BummyTunes.app for macOS.
#
# Two reasons this exists:
#   1. R1.2 asks for a Mac build.
#   2. There is no iOS simulator here, so this is the only way to actually
#      render the SwiftUI views and look at them. Same view code as iOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TC="$HOME/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr/bin"
SDK="$ROOT/toolchain/MacOSX15.5.sdk"
ORT_MAC="/opt/homebrew/opt/onnxruntime"
LLD="/opt/homebrew/opt/lld/bin/ld64.lld"
BUILD="$ROOT/build-mac"
APP="$BUILD/BummyTunes.app"
TARGET="arm64-apple-macos14.0"

for p in "$TC/swiftc" "$SDK" "$ORT_MAC" "$LLD"; do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

COMMON=(-target "$TARGET" -sdk "$SDK" -O
        -Xcc -DACCELERATE_NEW_LAPACK=1
        -I "$ROOT/app/Sources/COnnxRuntime/include"
        -Xcc -I"$ROOT/app/Sources/COnnxRuntime/include")

echo "==> core"
"$TC/swiftc" "${COMMON[@]}" \
  -module-name BummyTunesCore \
  -emit-module -emit-module-path "$BUILD/BummyTunesCore.swiftmodule" \
  -emit-library -static -o "$BUILD/libBummyTunesCore.a" \
  "$ROOT"/app/Sources/BummyTunesCore/*.swift

echo "==> app"
"$TC/swiftc" "${COMMON[@]}" \
  -module-name BummyTunes -parse-as-library \
  -I "$BUILD" -L "$BUILD" -lBummyTunesCore \
  -L "$ORT_MAC/lib" -lonnxruntime \
  -Xlinker -rpath -Xlinker "$ORT_MAC/lib" \
  -use-ld="$LLD" \
  -o "$APP/Contents/MacOS/BummyTunes" \
  "$ROOT"/app/Sources/BummyTunesApp/*.swift

cp "$ROOT/models/musicnn_embedding.onnx" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BummyTunes</string>
  <key>CFBundleIdentifier</key><string>com.bummy.tunes</string>
  <key>CFBundleExecutable</key><string>BummyTunes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

# Ad-hoc sign so the window server will accept it.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(unsigned, may still run)"

echo "built: $APP"
