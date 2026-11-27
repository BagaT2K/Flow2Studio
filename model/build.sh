#!/bin/bash
# Rebuilds the 3D assets of the Lofree Flow 2 and installs them in swift/Assets.
# Needs Blender (>= 4.2) and the Xcode command line tools.
set -euo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd)"
out="$here/out"
mkdir -p "$out" "$here/../swift/Assets"

gen="$(mktemp -d)/legends"
/usr/bin/xcrun swiftc -O "$here/legends.swift" -o "$gen"
"$gen" "$out/legends.png" 4096
"$gen" "$out/keycaps_dark.png" 4096 0.075,0.075,0.08 0.80,0.80,0.80
"$gen" "$out/keycaps_light.png" 4096 0.90,0.90,0.89 0.50,0.50,0.51

blender="${BLENDER:-$(command -v blender || echo /Applications/Blender.app/Contents/MacOS/Blender)}"
"$blender" -b --python "$here/build_flow2.py" -- --out "$out" --finish silver
"$blender" -b --python "$here/build_flow2.py" -- --out "$out" --finish spacegray --env "$@"

cp "$out/Flow2-84-spacegray.usdz" "$here/../swift/Assets/Flow2-84.usdz"
cp "$out/legends.png" "$out/studio_env.exr" "$here/../swift/Assets/"
echo "3D assets installed in swift/Assets"
