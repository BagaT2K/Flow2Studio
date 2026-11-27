#!/bin/bash
set -euo pipefail

studio_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/flow-operator-swift.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT

app_dir="$build_dir/Flow Operator.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$build_dir/obj"

echo "1/3 Compiling Objective-C HID & Firmware engine..."
objc_files=(
  "mac/FlowLocalization.m"
  "mac/FlowTransport.m"
  "mac/FlowBLEBattery.m"
  "mac/FlowBLESerial.m"
  "mac/FlowFirmware.m"
)
objs=()
for f in "${objc_files[@]}"; do
  base="$(basename "$f" .m)"
  out="$build_dir/obj/$base.o"
  /usr/bin/xcrun clang -c -fobjc-arc -fblocks -fno-modules \
    -isysroot "$sdk" -O2 -arch arm64 -mmacosx-version-min=14.0 \
    "$studio_dir/$f" -o "$out"
  objs+=("$out")
done

echo "2/3 Compiling Native SwiftUI Flow Operator..."
swift_files=()
while IFS= read -r -d '' f; do swift_files+=("$f"); done < <(/usr/bin/find "$studio_dir/swift" -name '*.swift' -print0 | /usr/bin/sort -z)
/usr/bin/xcrun swiftc \
  -O -sdk "$sdk" -target arm64-apple-macosx14.0 \
  -import-objc-header "$studio_dir/swift/FlowOperator-Bridging-Header.h" \
  "${swift_files[@]}" \
  "${objs[@]}" \
  -framework SwiftUI -framework AppKit -framework QuartzCore -framework SceneKit \
  -framework IOKit -framework CoreFoundation -framework IOBluetooth -framework CoreBluetooth \
  -framework CoreGraphics -framework UniformTypeIdentifiers \
  -o "$app_dir/Contents/MacOS/FlowOperator"

echo "3/3 Bundling resources & signing Flow Operator.app..."
/usr/bin/ditto "$studio_dir/firmware-bundle" "$app_dir/Contents/Resources/firmware"
/usr/bin/ditto "$studio_dir/Flow2Studio.icns" "$app_dir/Contents/Resources/Flow2Studio.icns"
# Engine messages: the catalogue FlowLocalized() reads to translate them
/usr/bin/ditto "$studio_dir/resources/locales.json" "$app_dir/Contents/Resources/ui/locales.json"
# Translations: French is the source language, the others live in swift/Localization
for lproj in "$studio_dir"/swift/Localization/*.lproj; do
  /usr/bin/ditto "$lproj" "$app_dir/Contents/Resources/$(basename "$lproj")"
done
# 3D keyboard: model, legend atlas and studio lighting (regenerate with model/build.sh)
for asset in Flow2-84.usdz legends.png studio_env.exr; do
  /usr/bin/ditto "$studio_dir/swift/Assets/$asset" "$app_dir/Contents/Resources/$asset"
done

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>fr</string>
<key>CFBundleLocalizations</key><array><string>fr</string><string>en</string><string>de</string><string>es</string><string>zh-Hans</string><string>ja</string><string>ko</string><string>ru</string></array>
<key>CFBundleName</key><string>Flow Operator</string>
<key>CFBundleDisplayName</key><string>Flow Operator</string>
<key>CFBundleIdentifier</key><string>app.flowoperator</string>
<key>CFBundleExecutable</key><string>FlowOperator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Flow2Studio</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>100</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Lire le niveau de batterie et configurer votre Lofree Flow 2 en Bluetooth.</string>
<key>NSInputMonitoringUsageDescription</key><string>Configurer votre Lofree Flow 2 et lire sa batterie via l’interface HID.</string>
</dict></plist>
PLIST

/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"

mkdir -p "$studio_dir/dist"
rm -rf -- "$studio_dir/dist/Flow Operator.app"
/usr/bin/ditto "$app_dir" "$studio_dir/dist/Flow Operator.app"
echo "✅ Built: $studio_dir/dist/Flow Operator.app"
