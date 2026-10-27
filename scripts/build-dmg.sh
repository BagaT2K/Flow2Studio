#!/bin/bash
set -euo pipefail
studio_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo 'Build the DMG on a Mac.';exit 1;fi
studio_python="$(command -v python3 || /usr/bin/xcrun --find python3)"
"$studio_python" -c 'import sys; assert sys.version_info >= (3, 7), "Python 3.7+ is required"'
"$studio_python" "$studio_root/tests/dmg-layout.py"
"$studio_python" "$studio_root/tests/source-snapshot.py"
bash "$studio_root/scripts/build-app.sh"
studio_stage="$(mktemp -d "${TMPDIR:-/tmp}/flow2-dmg.XXXXXX")"
studio_mount=""
cleanup_dmg(){
 if [[ -n "$studio_mount" ]]; then /usr/bin/hdiutil detach "$studio_mount" >/dev/null 2>&1 || true; fi
 rm -rf -- "$studio_stage"
}
trap cleanup_dmg EXIT
mkdir -p "$studio_stage/content/.background"
/usr/bin/xcrun clang -fobjc-arc -O2 -mmacosx-version-min=12.0 -framework AppKit "$studio_root/scripts/dmg-background.m" -o "$studio_stage/draw-background"
"$studio_stage/draw-background" "$studio_stage/content/.background/installer.png"
/usr/bin/ditto "$studio_root/dist/Flow2Studio.app" "$studio_stage/content/Flow2Studio.app"
ln -s /Applications "$studio_stage/content/Applications"
studio_dmg="$studio_root/dist/Flow2Studio-1.0.dmg"
# Avoid reopening an old mounted copy of this exact output file after rebuilding it.
"$studio_python" "$studio_root/scripts/unmount-dmg.py" "$studio_dmg"
/usr/bin/hdiutil create -ov -fs HFS+ -volname 'Flow2Studio 1.0' -srcfolder "$studio_stage/content" -format UDRW "$studio_stage/layout.dmg"
mkdir "$studio_stage/mounted"
/usr/bin/hdiutil attach -nobrowse -readwrite -mountpoint "$studio_stage/mounted" "$studio_stage/layout.dmg"
studio_mount="$(cd -- "$studio_stage/mounted" && pwd -P)"
# Persist Finder settings directly. A failed layout now fails the build.
"$studio_python" "$studio_root/scripts/write-dmg-layout.py" "$studio_mount"
/bin/sync
/usr/bin/hdiutil detach "$studio_mount"
studio_mount=""
/usr/bin/hdiutil convert "$studio_stage/layout.dmg" -ov -format UDZO -o "$studio_dmg"
# Read the final compressed image back before signing or distributing it.
/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$studio_stage/mounted" "$studio_dmg"
studio_mount="$(cd -- "$studio_stage/mounted" && pwd -P)"
"$studio_python" "$studio_root/scripts/write-dmg-layout.py" "$studio_mount" --verify
/usr/bin/hdiutil detach "$studio_mount"
studio_mount=""
if [[ "${FLOW2_SIGN_IDENTITY:--}" != - ]]; then
 /usr/bin/codesign --force --timestamp --sign "$FLOW2_SIGN_IDENTITY" --identifier app.flow2studio.dmg "$studio_dmg"
fi
if [[ -n "${FLOW2_NOTARY_PROFILE:-}" ]]; then
 if [[ "${FLOW2_SIGN_IDENTITY:--}" == - ]]; then echo 'A Developer ID signing identity is required for notarization.';exit 1;fi
 /usr/bin/xcrun notarytool submit "$studio_dmg" --keychain-profile "$FLOW2_NOTARY_PROFILE" --wait
 /usr/bin/xcrun stapler staple "$studio_dmg"
 /usr/bin/xcrun stapler validate "$studio_dmg"
fi
/usr/bin/hdiutil verify "$studio_dmg"
(
 cd "$studio_root/dist"
 /usr/bin/shasum -a 256 Flow2Studio-1.0.dmg > Flow2Studio-1.0.dmg.sha256
 /usr/bin/shasum -a 256 Flow2Studio-1.0.dmg Flow2Studio-1.0.2-source.zip > SHA256SUMS
)
echo "Ready: $studio_dmg"
if [[ "${FLOW2_SIGN_IDENTITY:--}" == - ]]; then echo 'Test build without Developer ID signing or Apple notarization.';fi
/usr/bin/open "$studio_dmg"
