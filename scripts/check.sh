#!/bin/bash
set -euo pipefail
studio_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
studio_checks="$(mktemp -d "${TMPDIR:-/tmp}/flow2-checks.XXXXXX")"
trap 'rm -rf -- "$studio_checks"' EXIT
studio_cc="${CC:-cc}"
for studio_test in keymap backup-file usb-battery editing-policy control-release; do
 "$studio_cc" -std=c11 -O2 -Wall -Wextra -Werror "$studio_root/tests/$studio_test.c" -o "$studio_checks/$studio_test"
 "$studio_checks/$studio_test"
done
"$studio_cc" -std=c11 -O2 -Wall -Wextra -Werror "$studio_root/tests/models-v14.c" -o "$studio_checks/models"
"$studio_checks/models" "$studio_root/firmware-bundle/factory-68-usb14.bin" "$studio_root/firmware-bundle/factory-84-usb14.bin" "$studio_root/firmware-bundle/factory-100-usb14.bin"
"$studio_cc" -std=c11 -O2 -Wall -Wextra -Werror "$studio_root/tests/firmware-migration.c" -o "$studio_checks/migration"
"$studio_checks/migration" "$studio_root/firmware-bundle/studio-v14-68.bin" "$studio_root/firmware-bundle/studio-v14-84.bin" "$studio_root/firmware-bundle/studio-v14-100.bin"
if [[ "$(uname -s)" == Darwin ]]; then
 studio_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
 for studio_native in events deferred localization updates window preferences; do
  studio_extra=("$studio_root/tests/native-$studio_native.m")
  case "$studio_native" in
   deferred) studio_extra+=("$studio_root/mac/FlowDeferredStore.m");;
   localization) studio_extra+=("$studio_root/mac/FlowLocalization.m");;
   updates) studio_extra+=("$studio_root/mac/FlowUpdates.m");;
  esac
  studio_check_app="$studio_checks/$studio_native.app"
  mkdir -p "$studio_check_app/Contents/MacOS" "$studio_check_app/Contents/Resources/ui"
  /bin/cp "$studio_root/resources/locales.json" "$studio_check_app/Contents/Resources/ui/locales.json"
  /usr/bin/xcrun clang -fobjc-arc -fblocks -fno-modules -isysroot "$studio_sdk" -O1 -Wall -Wextra -Werror=objc-method-access -mmacosx-version-min=12.0 -framework AppKit \
   "${studio_extra[@]}" -o "$studio_check_app/Contents/MacOS/Checks"
  cat > "$studio_check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Checks</string><key>CFBundleIdentifier</key><string>app.flow2studio.checks</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
  "$studio_check_app/Contents/MacOS/Checks"
 done
fi
