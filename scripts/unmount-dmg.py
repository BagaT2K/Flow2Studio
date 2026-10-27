"""Unmount only an already-mounted copy of the exact DMG being rebuilt."""
import os
import plistlib
import subprocess
import sys

target = os.path.realpath(sys.argv[1])
images = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"]))
for image in images.get("images", []):
    if os.path.realpath(image.get("image-path", "")) != target:
        continue
    mounts = [entity["mount-point"] for entity in image.get("system-entities", []) if "mount-point" in entity]
    for mount in mounts:
        # No force: a volume in use fails the build instead of closing user activity.
        subprocess.run(["/usr/bin/hdiutil", "detach", mount], check=True)
