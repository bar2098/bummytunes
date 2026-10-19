#!/bin/bash
# Build BummyTunes.app for iOS arm64 from the command line.
#
# Uses:
#   Xcode's Swift toolchain and iPhoneOS SDK (found with xcrun)
#   onnxruntime.xcframework ios-arm64 slice from download.onnxruntime.ai
#
# LiveContainer does not verify signatures, so the output is left unsigned.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-$(dirname "$(xcrun -f swiftc)")}"
SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
ORT="$ROOT/toolchain/ort/onnxruntime.xcframework/ios-arm64"
BUILD="$ROOT/build"
APP="$BUILD/Payload/BummyTunes.app"
TARGET="arm64-apple-ios17.0"

for p in "$TC/swiftc" "$SDK" "$ORT"; do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done

echo "==> clean"
rm -rf "$BUILD"
mkdir -p "$APP" "$BUILD/obj"

COMMON=(-target "$TARGET" -sdk "$SDK" -O
        -Xcc -DACCELERATE_NEW_LAPACK=1
        -I "$ROOT/app/Sources/COnnxRuntime/include"
        -Xcc -I"$ROOT/app/Sources/COnnxRuntime/include"
        -F "$ORT")

echo "==> compile BummyTunesCore"
"$TC/swiftc" "${COMMON[@]}" \
  -module-name BummyTunesCore \
  -emit-module -emit-module-path "$BUILD/BummyTunesCore.swiftmodule" \
  -emit-library -static -o "$BUILD/libBummyTunesCore.a" \
  "$ROOT"/app/Sources/BummyTunesCore/*.swift

echo "==> compile app"
"$TC/swiftc" "${COMMON[@]}" \
  -module-name BummyTunes -parse-as-library \
  -I "$BUILD" \
  -L "$BUILD" -lBummyTunesCore \
  -framework onnxruntime \
  -lc++ -lc++abi \
  -o "$APP/BummyTunes" \
  "$ROOT"/app/Sources/BummyTunesApp/*.swift

echo "==> bundle"
# No Frameworks directory on purpose. The onnxruntime "framework" ships a
# static archive, not a dylib, so the linker above pulls it straight into the
# executable. Copying it into the bundle leaves LiveContainer a Mach-O it
# cannot load, and it refuses to install the app: "Invalid mach-o file".
cp "$ROOT/models/musicnn_embedding.onnx" "$APP/"
# Loose icon files. Without Xcode there is no actool to compile an asset
# catalogue, but iOS still honours CFBundleIconFiles with PNGs in the bundle.
cp "$ROOT"/icon/AppIcon*.png "$APP/"

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BummyTunes</string>
  <key>CFBundleDisplayName</key><string>BummyTunes</string>
  <key>CFBundleIdentifier</key><string>com.bummy.tunes</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>BummyTunes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UILaunchScreen</key><dict/>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFiles</key>
  <array>
    <string>AppIcon60x60</string>
    <string>AppIcon40x40</string>
    <string>AppIcon29x29</string>
    <string>AppIcon76x76</string>
  </array>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>AppIcon60x60</string>
        <string>AppIcon40x40</string>
        <string>AppIcon29x29</string>
      </array>
      <key>CFBundleIconName</key><string>AppIcon</string>
    </dict>
  </dict>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <!-- Landscape is Cover Flow, so the app has to be allowed to turn. -->
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <!-- Audio keeps playback alive when locked, and is what grants CPU time for
       background analysis under LiveContainer, where BGProcessingTask cannot
       register. -->
  <key>UIBackgroundModes</key><array><string>audio</string></array>
  <!-- Let the user reach their music from Files. -->
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
</dict>
</plist>
PLIST

echo "==> package"
cd "$BUILD"
zip -qry BummyTunes.ipa Payload
BIN="$APP/BummyTunes"
echo
echo "binary   : $("$TC/../usr/bin/file" "$BIN" 2>/dev/null || file "$BIN")"
"$TC/llvm-objdump" --macho --all-headers "$BIN" 2>/dev/null \
  | grep -A4 LC_BUILD_VERSION | head -6
echo "app      : $(du -sh "$APP" | cut -f1)"
echo "ipa      : $BUILD/BummyTunes.ipa ($(du -h BummyTunes.ipa | cut -f1))"
