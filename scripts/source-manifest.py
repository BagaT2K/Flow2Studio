"""Record exact project inputs and optionally emit the matching source archive."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import zipfile

SOURCE_DIRS = ("mac", "resources", "firmware", "firmware-bundle", "localization", "scripts", "tests")
ROOT_FILES = ("LICENSE", "README.md", "Build-DMG.command", "Build-and-Run.command", "Flow2Studio.icns", ".gitignore")


def collect_sources(root):
    root = Path(root).resolve()
    files = [root / name for name in ROOT_FILES]
    for name in SOURCE_DIRS:
        files.extend((root / name).rglob("*"))
    selected = {}
    for file in files:
        relative = file.relative_to(root)
        if any(part in ("__pycache__", ".git", "node_modules", "dist") for part in relative.parts):
            continue
        if file.name == ".DS_Store" or file.name.startswith(".env") or file.suffix in (".pyc", ".p12", ".pfx", ".key"):
            continue
        if file.is_symlink():
            raise ValueError("Source snapshot must not follow symlinks: " + str(relative))
        if file.is_file():
            selected[relative.as_posix()] = file
    return sorted(selected.items())


def snapshot(root, destination, archive=None):
    root = Path(root).resolve()
    script = (root / "scripts/build-app.sh").read_text()
    version = re.search(r"<key>CFBundleShortVersionString</key><string>([^<]+)</string>", script).group(1)
    sources = collect_sources(root)
    # Read each file once; the archived bytes and their recorded hashes are identical.
    contents = [(name, file, file.read_bytes()) for name, file in sources]
    manifest = {
        "format": 1,
        "applicationVersion": version,
        "license": "MIT for original project code; third-party components retain their own terms",
        "purpose": "Build input inventory; not a signature or proof of executable equivalence",
        "files": [{"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                  for name, file, data in contents],
    }
    raw = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(raw)
    if archive:
        archive = Path(archive)
        archive.parent.mkdir(parents=True, exist_ok=True)
        prefix = "Flow2-Studio-" + version
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as output:
            for name, file, data in contents:
                entry = zipfile.ZipInfo(prefix + "/" + name)
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (file.stat().st_mode & 0xFFFF) << 16
                output.writestr(entry, data)
            output.writestr(prefix + "/source-manifest.json", raw)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root")
    parser.add_argument("destination")
    parser.add_argument("--archive")
    args = parser.parse_args()
    result = snapshot(args.root, args.destination, args.archive)
    print("Source snapshot recorded:", result["applicationVersion"], len(result["files"]), "files")
