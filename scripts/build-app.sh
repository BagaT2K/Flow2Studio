#!/bin/bash
set -euo pipefail
studio_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo 'Build this app on a Mac.'; exit 1; fi
if ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then echo 'Install Apple Command Line Tools: xcode-select --install';exit 1;fi
studio_build="$(mktemp -d "${TMPDIR:-/tmp}/flow2-studio.XXXXXX")"
trap 'rm -rf -- "$studio_build"' EXIT
studio_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
studio_app="$studio_build/Flow2Studio.app"
mkdir -p "$studio_app/Contents/MacOS" "$studio_app/Contents/Resources/ui"
bash "$studio_dir/scripts/check.sh"
echo 'Building Flow2Studio...' 
/usr/bin/xcrun clang -fobjc-arc -fblocks -fno-modules -isysroot "$studio_sdk" \
  -O2 -Wall -Wextra -Werror=objc-method-access -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -framework UniformTypeIdentifiers -framework AppKit -framework CoreGraphics -framework WebKit -framework IOKit -framework CoreFoundation -framework IOBluetooth -framework CoreBluetooth \
  "$studio_dir/mac/FlowUpdates.m" "$studio_dir/mac/FlowLocalization.m" "$studio_dir/mac/FlowMacroRecorder.m" "$studio_dir/mac/FlowDeferredStore.m" "$studio_dir/mac/Studio.m" "$studio_dir/mac/FlowTransport.m" "$studio_dir/mac/FlowBLEBattery.m" "$studio_dir/mac/FlowBLESerial.m" "$studio_dir/mac/FlowFirmware.m" \
  -o "$studio_app/Contents/MacOS/Flow2Studio"
/usr/bin/ditto "$studio_dir/firmware-bundle" "$studio_app/Contents/Resources/firmware"
/usr/bin/ditto "$studio_dir/resources" "$studio_app/Contents/Resources/ui"
/usr/bin/ditto "$studio_dir/Flow2Studio.icns" "$studio_app/Contents/Resources/Flow2Studio.icns"
cat > "$studio_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Flow 2 Studio</string>
<key>CFBundleIdentifier</key><string>app.flow2studio</string>
<key>CFBundleExecutable</key><string>Flow2Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Flow2Studio</string>
<key>CFBundleShortVersionString</key><string>0.9.6</string>
<key>CFBundleVersion</key><string>63</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 BagaT2K. MIT; see LICENSE.</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Read the battery level and configure your connected Lofree Flow 2 over Bluetooth.</string>
<key>NSInputMonitoringUsageDescription</key><string>Configure your Flow 2 and read its battery level through the keyboard control interface.</string>
</dict></plist>
PLIST
studio_python="$(command -v python3 || /usr/bin/xcrun --find python3)"
mkdir -p "$studio_dir/dist" "$studio_app/Contents/Resources/Legal"
for studio_notice in LICENSE README.md; do
 /usr/bin/ditto "$studio_dir/$studio_notice" "$studio_app/Contents/Resources/Legal/$studio_notice"
done
"$studio_python" "$studio_dir/scripts/source-manifest.py" "$studio_dir" \
 "$studio_app/Contents/Resources/Legal/source-manifest.json" \
 --archive "$studio_dir/dist/Flow2Studio-0.9.6-source.zip"
if [[ "${FLOW2_SIGN_IDENTITY:--}" == - ]]; then
 /usr/bin/codesign --force --sign - "$studio_app"
else
 /usr/bin/codesign --force --options runtime --timestamp --sign "$FLOW2_SIGN_IDENTITY" "$studio_app"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$studio_app"
mkdir -p "$studio_dir/dist"
# Never overwrite an installed app here; this folder is build output only.
rm -rf -- "$studio_dir/dist/Flow2Studio.app"
/usr/bin/ditto "$studio_app" "$studio_dir/dist/Flow2Studio.app"

